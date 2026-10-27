import AppKit
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // "Haptic feedback when reordering tabs", on by default.
  static var tabReorderingHaptics: Self { Self[.appStorage("tabReorderingHaptics"), default: true] }
}

// The Advanced pane: its toggles, Chromium's settings pages, and Export Data.
struct AdvancedPane: View {
  let store: StoreOf<AppFeature>
  let openPage: (URL, Profile.ID) -> Void
  @Shared(.tabReorderingHaptics) private var tabReorderingHaptics
  @Shared(.soundEffects) private var soundEffects

  var body: some View {
    VStack(spacing: 10) {
      VStack(spacing: 0) {
        AdvancedToggle("Play Sailfish sound effects", symbol: "speaker.wave.2.fill", color: .blue, isOn: $soundEffects)
        Divider().padding(.horizontal, 10)
        AdvancedToggle("Haptic feedback when reordering tabs", symbol: "hand.tap.fill", color: .blue, isOn: $tabReorderingHaptics)
      }
      .settingsCard()
      SpaceSwipeTuning()
      VStack(spacing: 0) {
        link("Privacy and Security", symbol: "lock.fill", color: .blue, page: "chrome://settings/privacy")
        Divider().padding(.horizontal, 10)
        link("Language Settings", symbol: "globe", color: .green, page: "chrome://settings/languages")
        Divider().padding(.horizontal, 10)
        link("All Site Settings", symbol: "slider.horizontal.3", color: .purple, page: "chrome://settings/content")
      }
      .settingsCard()
      HStack {
        Button("More Settings…") { open("chrome://settings") }
        Button("Clear Browsing Data…") { open("chrome://settings/clearBrowserData") }
        Spacer()
        Button("Export Data", action: exportData)
      }
      .padding(.top, 4)
    }
    .padding(.vertical, 20)
    .padding(.horizontal, 64)
  }

  private func link(_ title: String, symbol: String, color: Color, page: String) -> some View {
    HStack(spacing: 10) {
      AdvancedIcon(symbol: symbol, color: color)
      Text(title).font(.system(size: 13))
      Spacer()
      Image(systemName: "arrow.right").foregroundStyle(Color.accentColor)
    }
    .padding(.horizontal, 10)
    .frame(height: 40)
    .contentShape(Rectangle())
    .onTapGesture { open(page) }
  }

  private var profile: Profile.ID {
    store.windows.last { !$0.isIncognito }?.spaces.selected.profileID ?? store.profiles[0].id
  }

  private func open(_ page: String) {
    openPage(URL(string: page)!, profile)
  }

  // Saves every regular window's spaces as Markdown.
  private func exportData() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(ProcessInfo.processInfo.processName) Export.md"
    panel.allowedContentTypes = [.init(filenameExtension: "md")!]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let spaces = store.windows.filter { !$0.isIncognito }.flatMap(\.spaces.spaces)
    do {
      try ExportData.markdown(spaces).write(to: url, atomically: true, encoding: .utf8)
    } catch {
      NSAlert(error: error).runModal()
    }
  }
}

// The Advanced rows: a colored 22 pt icon, the label and a switch.
private struct AdvancedToggle: View {
  let title: String
  let symbol: String
  let color: Color
  @Shared var isOn: Bool

  init(_ title: String, symbol: String, color: Color, isOn: Shared<Bool>) {
    self.title = title
    self.symbol = symbol
    self.color = color
    _isOn = isOn
  }

  var body: some View {
    HStack(spacing: 10) {
      AdvancedIcon(symbol: symbol, color: color)
      Text(title).font(.system(size: 13))
      Spacer()
      Toggle("", isOn: Binding($isOn)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
    }
    .padding(.horizontal, 10)
    .frame(height: 40)
  }
}

struct AdvancedIcon: View {
  let symbol: String
  let color: Color

  var body: some View {
    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.white)
      .frame(width: 22, height: 22).background(color, in: RoundedRectangle(cornerRadius: 5))
  }
}
