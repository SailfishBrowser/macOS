import ComposableArchitecture
import SwiftUI

// The WebKit Sites sheet: Add Site, each rule's site and engine in list order, and the streaming sites.
struct WebKitSites: View {
  let dismiss: () -> Void
  @Shared(.siteEngines) private var siteEngines
  @FocusState private var focused: SiteRule.ID?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("WebKit Sites").font(.system(size: 14, weight: .semibold))
        Spacer()
        Button {
          let rule = SiteRule(id: UUID(), host: "", engine: .webkit)
          $siteEngines.withLock { $0.rules.append(rule) }
          // Its field exists from the next update.
          DispatchQueue.main.async { focused = rule.id }
        } label: {
          Text("Add Site").frame(width: 98)
        }
        Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 14)) }
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          .padding(.leading, 28)
          .padding(.trailing, 8)
      }
      .padding(.bottom, 26)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if !siteEngines.rules.isEmpty {
            HStack(spacing: 10) {
              Text("Site").frame(width: RuleRow.siteWidth, alignment: .leading)
              Text("Opens in")
            }
            .foregroundStyle(.secondary)
          }
          ForEach(Binding($siteEngines).rules) { $rule in
            RuleRow(rule: $rule, focused: $focused, commit: { commit(rule.id) }) {
              $siteEngines.withLock { $0.rules.removeAll { $0.id == rule.id } }
            }
          }
          Text("Streaming Sites").font(.system(size: 13, weight: .semibold))
            .padding(.top, siteEngines.rules.isEmpty ? 0 : 14)
          Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(SiteEngines.groups, id: \.name) { group in
              GridRow {
                Text(group.name).foregroundStyle(.secondary)
                Text(group.webKit.joined(separator: ", ")).fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          .opacity(siteEngines.streamingSitesInWebKit ? 1 : 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
      }
    }
    .font(.system(size: 13))
    .padding(.horizontal, 24)
    .padding(.vertical, 19)
    .padding(.top, 19)
    .frame(width: 506, height: 498)
    .background(Color(hex: 0x161C2F))
    // The sheet opens with no field focused. A site is kept as typed until its field is left, and as it closes a
    // site still being typed is kept and an empty one goes.
    .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
    .onChange(of: focused) { old, _ in
      if let old { commit(old) }
    }
    .onDisappear {
      $siteEngines.withLock { settings in
        settings.rules.indices.forEach { settings.rules[$0].host = SiteEngines.site(from: settings.rules[$0].host) }
        settings.rules.removeAll { $0.host.isEmpty }
      }
    }
  }

  private func commit(_ id: SiteRule.ID) {
    $siteEngines.withLock { settings in
      guard let index = settings.rules.firstIndex(where: { $0.id == id }) else { return }
      settings.rules[index].host = SiteEngines.site(from: settings.rules[index].host)
    }
  }
}

// A rule: its site, typed as any address and kept as its registrable domain, the engine it opens in, and remove.
private struct RuleRow: View {
  static let siteWidth: CGFloat = 240
  @Binding var rule: SiteRule
  let focused: FocusState<SiteRule.ID?>.Binding
  let commit: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      TextField("example.com", text: $rule.host)
        .textFieldStyle(.roundedBorder)
        .frame(width: Self.siteWidth)
        .focused(focused, equals: rule.id)
        .onSubmit(commit)
      Picker("", selection: $rule.engine) {
        Text(PageEngineKind.chromium.name).tag(PageEngineKind.chromium)
        Text(PageEngineKind.webkit.name).tag(PageEngineKind.webkit)
      }
      .labelsHidden()
      .frame(width: 130)
      Button(action: remove) { Image(systemName: "minus.circle.fill") }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
  }
}
