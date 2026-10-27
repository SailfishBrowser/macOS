import ComposableArchitecture
import EngineCore
import SwiftUI

struct ExtensionsView: View {
  let context: ECBrowserContext
  // Opens Chrome's page for one extension, with its details, site access and incognito setting.
  let showDetails: (String) -> Void
  let done: () -> Void

  var body: some View {
    let _ = Engine.shared.extensionsRevision
    let extensions = context.extensions
    VStack(alignment: .leading, spacing: 10) {
      Text("Extensions").font(.headline)
      if extensions.isEmpty {
        Text("No extensions. Add them from the Chrome Web Store.").foregroundStyle(.secondary)
      }
      ForEach(extensions, id: \.identifier) { item in
        HStack(spacing: 10) {
          Image(nsImage: item.icon ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!)
            .resizable()
            .frame(width: 20, height: 20)
          Text(item.name).lineLimit(1)
          Spacer()
          if item.isBuiltIn {
            Text("Built in; turn it off in Settings").foregroundStyle(.secondary)
          } else {
            Toggle("", isOn: Binding(get: { item.isEnabled }, set: { context.setEnabled($0, forExtension: item.identifier) }))
              .toggleStyle(.switch)
              .labelsHidden()
            Button("Details") { showDetails(item.identifier) }
            Button("Remove") { confirmRemoval(of: item, from: context) }
          }
        }
      }
      HStack {
        Spacer()
        Button("Done", action: done).keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(width: 380)
  }
}

// An extension's action as a site controls tile.
struct ActionTile: View {
  let item: ExtensionAction
  let run: () -> ECExtensionPopup?
  @State private var popup: ExtensionPopup?

  var body: some View {
    ExtensionButton(item: item, run: run, popup: $popup) { icon in
      icon
        .frame(width: 16, height: 16)
        .frame(width: 49, height: 30)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
    }
  }
}

// An extension's action button: a click runs it and shows its popup beside the button, and right-click pins,
// turns off, removes or manages it.
struct ExtensionButton<Label: View>: View {
  let item: ExtensionAction
  let run: () -> ECExtensionPopup?
  @Binding var popup: ExtensionPopup?
  @ViewBuilder let label: (AnyView) -> Label
  @Shared(.pinnedExtensions) private var pinned

  var body: some View {
    let action = item.action
    Button { popup = run().map(ExtensionPopup.init) } label: {
      label(AnyView(icon))
        .overlay(alignment: .bottomTrailing) {
          if !action.badgeText.isEmpty {
            let color = action.badgeBackgroundColor
            Text(action.badgeText)
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.white)
              .padding(.horizontal, 3)
              .background(color.alphaComponent > 0 ? Color(nsColor: color) : Theme.accent, in: Capsule())
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(action.title)
    .contextMenu {
      let isPinned = pinned[item.profile]?.contains(item.id) == true
      Button(isPinned ? "Unpin" : "Pin") {
        $pinned.withLock { isPinned ? $0[item.profile]?.removeAll { $0 == item.id } : $0[item.profile, default: []].append(item.id) }
      }
      if !item.extension.isBuiltIn {
        Button("Turn Off") { item.context.setEnabled(false, forExtension: item.id) }
        Button("Remove from \(ProcessInfo.processInfo.processName)…") { confirmRemoval(of: item.extension, from: item.context) }
      }
      Divider()
      Button("Manage Extensions…") {
        NSApp.sendAction(#selector(WindowController.showExtensions(_:)), to: nil, from: nil)
      }
    }
    .disabled(!action.isEnabled)
    .opacity(action.isEnabled ? 1 : 0.45)
    .popover(isPresented: Binding(get: { popup?.isOpen == true }, set: { if !$0 { popup?.close() } }), arrowEdge: .bottom) {
      if let popup {
        WebView(view: popup.popup.view).frame(width: popup.size.width, height: popup.size.height)
      }
    }
  }

  private var icon: some View {
    Group {
      if let icon = item.action.icon {
        Image(nsImage: icon).resizable()
      } else {
        Image(systemName: "puzzlepiece.extension").foregroundStyle(Theme.icon)
      }
    }
  }
}
