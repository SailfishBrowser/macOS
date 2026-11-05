import AppKit
import ComposableArchitecture
import SwiftUI

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  static var warnBeforeQuitting: Self { Self[.appStorage("warnBeforeQuitting"), default: true] }
}

extension SharedKey where Self == AppStorageKey<TimeInterval?> {
  // How long a tab goes unshown before its page closes, in seconds; nil never.
  static var sleepTabsAfter: Self { .appStorage("sleepTabsAfter") }
}

struct GeneralPane: View {
  let showProfiles: () -> Void
  let importData: () -> Void
  @Shared(.warnBeforeQuitting) private var warnBeforeQuitting
  @Shared(.blocksAds) private var blocksAds
  @Shared(.fingerprintingProtection) private var fingerprintingProtection
  @Shared(.httpsOnly) private var httpsOnly
  @Shared(.tidyDownloads) private var tidyDownloads
  @Shared(.sleepTabsAfter) private var sleepTabsAfter
  @State private var isDefaultBrowser = Shell.isDefaultBrowser

  var body: some View {
    VStack(spacing: 10) {
      VStack(spacing: 0) {
        SettingsToggle("Warn before quitting", isOn: $warnBeforeQuitting)
        Divider().padding(.horizontal, 10)
        SettingsToggle("Block ads and trackers with uBlock Origin", isOn: $blocksAds)
          .onChange(of: blocksAds) { Engine.shared.adBlockingDidChange() }
        Divider().padding(.horizontal, 10)
        SettingsToggle("Fingerprinting protection", isOn: $fingerprintingProtection)
          .onChange(of: fingerprintingProtection) { Engine.shared.fingerprintingDidChange() }
        Divider().padding(.horizontal, 10)
        SettingsToggle("Always use secure connections", isOn: $httpsOnly)
          .onChange(of: httpsOnly) { Engine.shared.httpsOnlyDidChange() }
        Divider().padding(.horizontal, 10)
        SettingsToggle("Tidy Downloads", isOn: $tidyDownloads)
        if !isDefaultBrowser {
          Divider().padding(.horizontal, 10)
          SettingsRow("Default browser") {
            Button("Set as Default", action: makeDefault)
          }
        }
      }
      .settingsCard()
      SettingsRow("Sleep tabs after") {
        Picker("", selection: Binding { sleepTabsAfter } set: { value in $sleepTabsAfter.withLock { $0 = value } }) {
          ForEach([15.0, 30, 60, 120, 360, 720], id: \.self) { minutes in
            Text(minutes < 60 ? "\(Int(minutes)) minutes" : minutes == 60 ? "1 hour" : "\(Int(minutes / 60)) hours")
              .tag(Optional(minutes * 60))
          }
          Text("Never").tag(TimeInterval?.none)
        }
        .labelsHidden()
        .frame(width: 180)
      }
      .settingsCard()
      VStack(spacing: 0) {
        SettingsRow("Search engine, Auto-Archive and downloads") {
          Button("Profile Settings…", action: showProfiles)
        }
        Divider().padding(.horizontal, 10)
        SettingsRow("Import Data") {
          Button("Import…", action: importData)
        }
      }
      .settingsCard()
    }
    .padding(.vertical, 20)
    .padding(.horizontal, 64)
  }

  private func makeDefault() {
    Task {
      await Shell.makeDefaultBrowser()
      isDefaultBrowser = Shell.isDefaultBrowser
    }
  }
}

// With "Warn before quitting" on, quitting first asks "Quit Sailfish?" over the last focused window: Return, the
// Quit button or a second quit quits, and Escape or Cancel closes it; other keys do nothing while it shows. Quit chosen
// from the menu bar counts as the keys. AppleScript, the Dock and a logout ask as well: AppKit runs terminate(_:) for a
// quit Apple event on a later turn of the run loop, when the event is no longer current, so its sender and reason go
// unread, and the AppleScript call returns before the answer. Only a quit with no window to ask in quits at once.
// While files download it asks about those instead, as quitting cancels them. Every route to quitting, the menu, the
// Dock, AppleScript and logout included, comes through NSApp.terminate(_:), which the engine's application class owns,
// so the warning wraps that method rather than the app delegate.
@MainActor
final class QuitWarning {
  enum Prompt: Equatable { case none, downloads, confirm }

  private static var shared: QuitWarning!
  @Shared(.warnBeforeQuitting) private var isEnabled
  // Set when Sparkle quits to install an update and relaunch.
  var bypass = false
  private let store: StoreOf<AppFeature>
  private let showWindow: (WindowFeature.State.ID) -> Void

  init(store: StoreOf<AppFeature>, showWindow: @escaping (WindowFeature.State.ID) -> Void) {
    self.store = store
    self.showWindow = showWindow
  }

  // Logout, restart and shutdown send a quit event with a reason, and must not wait on a dialog.
  static func prompt(bypass: Bool, isSystemQuit: Bool, isDownloading: Bool, isEnabled: Bool) -> Prompt {
    if bypass || isSystemQuit { return .none }
    if isDownloading { return .downloads }
    return isEnabled ? .confirm : .none
  }

  static func addKeyMonitor(_ handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any? {
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      shared.confirmingWindow == nil ? handler(event) : event
    }
  }

  func install() {
    Self.shared = self
    let selector = #selector(NSApplication.terminate(_:))
    let method = class_getInstanceMethod(object_getClass(NSApp), selector)!
    typealias Terminate = @convention(c) (NSApplication, Selector, Any?) -> Void
    let terminate = unsafeBitCast(method_getImplementation(method), to: Terminate.self)
    let block: @convention(block) (NSApplication, Any?) -> Void = { [unowned self] app, sender in
      MainActor.assumeIsolated {
        if mayQuit() { terminate(app, selector, sender) }
      }
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
    _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
      if event.isARepeat, isQuitKey(event) { return nil }
      guard let window = confirmingWindow, !isQuitKey(event) else { return event }
      switch event.keyCode {
      case 36, 76:
        NSApp.terminate(nil)
      case 53:
        store.send(.windows(.element(id: window, action: .confirmQuit(false))))
      default:
        break
      }
      return nil
    }
  }

  private var quitItem: NSMenuItem {
    MenuShortcuts.items(in: NSApp.mainMenu!).first { $0.action == #selector(NSApplication.terminate(_:)) }!
  }

  private func isQuitKey(_ event: NSEvent) -> Bool {
    KeyBinding(event) == KeyBinding(quitItem).normalized
  }

  private var confirmingWindow: WindowFeature.State.ID? {
    store.windows.first(where: \.isConfirmingQuit)?.id
  }

  private var quitEvent: NSAppleEventDescriptor? {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication
    else { return nil }
    return event
  }

  private func mayQuit() -> Bool {
    let isSystemQuit = quitEvent?.paramDescriptor(forKeyword: kAEQuitReason) != nil
    let prompt = Self.prompt(
      bypass: bypass, isSystemQuit: isSystemQuit, isDownloading: store.downloads.downloads.progress != nil,
      isEnabled: isEnabled)
    switch prompt {
    case .none:
      return true
    case .downloads:
      let alert = NSAlert()
      alert.messageText = "Downloads in progress"
      alert.informativeText = "There are downloads in progress. Closing the application will cancel them."
      alert.addButton(withTitle: "Quit")
      alert.addButton(withTitle: "Cancel")
      return alert.runModal() == .alertFirstButtonReturn
    case .confirm:
      guard quitEvent == nil, confirmingWindow == nil, let window = store.state.toastWindowID else { return true }
      showWindow(window)
      store.send(.windows(.element(id: window, action: .confirmQuit(true))))
      return false
    }
  }
}
