import AppKit
import ComposableArchitecture
import SwiftUI

// The Settings window's panes in tab order; a pane's raw value is its tab index and the tag that opens it.
enum SettingsPane: Int, CaseIterable {
  case general, profiles, links, shortcuts, icon, advanced
}

// The Settings window: a toolbar tab per pane, titled after the selected one, at a fixed size.
@MainActor
func makeSettingsWindow(
  store: StoreOf<AppFeature>, openPage: @escaping (URL, Profile.ID) -> Void, importData: @escaping () -> Void
) -> NSWindow {
  let tabs = SettingsTabs()
  tabs.tabStyle = .toolbar
  let symbol = { NSImage(systemSymbolName: $0, accessibilityDescription: nil)! }
  let panes = SettingsPane.allCases.map { pane -> (String, NSImage, AnyView) in
    switch pane {
    case .general:
      ("General", symbol("gearshape"), AnyView(GeneralPane(showProfiles: { [weak tabs] in tabs?.selectedTabViewItemIndex = SettingsPane.profiles.rawValue }, importData: importData)))
    case .profiles: ("Profiles", symbol("person"), AnyView(ProfilesPane(store: store, openPage: openPage)))
    case .links: ("Links", symbol("macwindow.on.rectangle"), AnyView(LinksPane(store: store)))
    case .shortcuts: ("Shortcuts", symbol("keyboard"), AnyView(ShortcutsPane()))
    case .icon: ("Icon", appIconTabImage(), AnyView(IconPane()))
    case .advanced: ("Advanced", symbol("slider.horizontal.3"), AnyView(AdvancedPane(store: store, openPage: openPage)))
    }
  }
  for (label, image, pane) in panes {
    let host = NSHostingController(rootView: pane.frame(width: 684, height: 562, alignment: .top))
    host.sizingOptions = .preferredContentSize
    host.title = label
    let item = NSTabViewItem(viewController: host)
    item.label = label
    item.image = image
    tabs.addTabViewItem(item)
  }
  let window = NSWindow(contentViewController: tabs)
  window.styleMask = [.titled, .closable]
  window.toolbarStyle = .preference
  window.title = panes[0].0
  window.isReleasedWhenClosed = false
  window.appearance = NSAppearance(named: .darkAqua)
  window.backgroundColor = NSColor(Color(hex: 0x292C32))
  window.center()
  return window
}

// The Icon tab shows the app's own icon and follows the icon chosen in that pane.
@MainActor
private func appIconTabImage() -> NSImage {
  let chosen = AppIcon(rawValue: UserDefaults.standard.string(forKey: AppIcon.defaultsKey) ?? "") ?? .original
  let image = chosen.image()
  image.size = NSSize(width: 26, height: 26)
  return image
}

private final class SettingsTabs: NSTabViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    NotificationCenter.default.addObserver(
      self, selector: #selector(iconChanged), name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
  }

  @objc private func iconChanged() {
    tabViewItems.first { $0.label == "Icon" }?.image = appIconTabImage()
  }
}

// A settings card row: a 13 pt label on the left and its control on the right.
struct SettingsRow<Control: View>: View {
  let title: String
  @ViewBuilder let control: Control

  init(_ title: String, @ViewBuilder control: () -> Control) {
    self.title = title
    self.control = control()
  }

  var body: some View {
    HStack {
      Text(title).font(.system(size: 13))
      Spacer()
      control
    }
    .padding(.horizontal, 10)
    .frame(minHeight: 36)
  }
}

struct SettingsToggle: View {
  let title: String
  @Shared var isOn: Bool

  init(_ title: String, isOn: Shared<Bool>) {
    self.title = title
    _isOn = isOn
  }

  var body: some View {
    SettingsRow(title) {
      Toggle("", isOn: Binding($isOn)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
    }
  }
}

extension View {
  // The settings cards: darker than the window, with a hairline border.
  func settingsCard() -> some View {
    background(Color(hex: 0x2C2F34), in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
  }
}
