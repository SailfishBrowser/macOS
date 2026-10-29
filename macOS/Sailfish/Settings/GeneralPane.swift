import AppKit
import ComposableArchitecture
import SwiftUI

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  static var warnBeforeQuitting: Self { Self[.appStorage("warnBeforeQuitting"), default: true] }
}

struct GeneralPane: View {
  let showProfiles: () -> Void
  let importData: () -> Void
  @Shared(.warnBeforeQuitting) private var warnBeforeQuitting
  @Shared(.blocksAds) private var blocksAds
  @Shared(.tidyDownloads) private var tidyDownloads
  @State private var isDefaultBrowser = Shell.isDefaultBrowser

  var body: some View {
    VStack(spacing: 10) {
      VStack(spacing: 0) {
        SettingsToggle("Warn before quitting", isOn: $warnBeforeQuitting)
        Divider().padding(.horizontal, 10)
        SettingsToggle("Block ads and trackers with uBlock Origin", isOn: $blocksAds)
          .onChange(of: blocksAds) { Engine.shared.adBlockingDidChange() }
        Divider().padding(.horizontal, 10)
        SettingsToggle("Tidy Downloads: let Sailfish rename downloads so they're easier to find later", isOn: $tidyDownloads)
        if !isDefaultBrowser {
          Divider().padding(.horizontal, 10)
          SettingsRow("Make Sailfish your default browser so links open here") {
            Button("Set as Default", action: makeDefault)
          }
        }
      }
      .settingsCard()
      SettingsRow("Manage your default search engine, Auto-Archive, and downloads in Profile Settings.") {
        Button("Profile Settings…", action: showProfiles)
      }
      .settingsCard()
      VStack(alignment: .leading, spacing: 0) {
        Text("Import Data").font(.system(size: 13, weight: .semibold)).padding([.horizontal, .top], 10)
        SettingsRow("Bring in Arc's spaces, or bookmarks and history from Chrome, Dia, Edge or Safari.") {
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

// With "Warn before quitting" on, the first ⌘Q shows "⌘Q again to quit" for two seconds, and a second ⌘Q while it
// shows quits; any other key closes it. Quit chosen from the menu bar counts as the keys. AppleScript and the Dock quit
// at once, as does a quit with no window to show the toast in. While files download it asks about those instead, as
// quitting cancels them. Every route to quitting, the menu, the Dock, AppleScript and logout included, comes through
// NSApp.terminate(_:), which the engine's application class owns, so the warning wraps that method rather than the
// app delegate.
@MainActor
final class QuitWarning {
  enum Prompt: Equatable { case none, downloads, confirm }

  @Shared(.warnBeforeQuitting) private var isEnabled
  // Set when Sparkle quits to install an update and relaunch.
  var bypass = false
  private let store: StoreOf<AppFeature>
  // The first press's toast and its window; a second press quits while that toast shows.
  private var pending: (window: WindowFeature.State.ID, toast: Toast.ID)?

  init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  // Logout, restart and shutdown send a quit event with a reason, and must not wait on a dialog.
  static func prompt(bypass: Bool, isSystemQuit: Bool, isDownloading: Bool, isEnabled: Bool) -> Prompt {
    if bypass || isSystemQuit { return .none }
    if isDownloading { return .downloads }
    return isEnabled ? .confirm : .none
  }

  func install() {
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
      if let pending, !isQuitKey(event) {
        store.send(.windows(.element(id: pending.window, action: .dismissToast(pending.toast))), animation: Motion.layout)
        self.pending = nil
      }
      return event
    }
  }

  private var quitItem: NSMenuItem {
    MenuShortcuts.items(in: NSApp.mainMenu!).first { $0.action == #selector(NSApplication.terminate(_:)) }!
  }

  private func isQuitKey(_ event: NSEvent) -> Bool {
    KeyBinding(event) == KeyBinding(quitItem).normalized
  }

  private var isShowingToast: Bool {
    pending.map { store.windows[id: $0.window]?.toast?.id == $0.toast } ?? false
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
      guard quitEvent == nil, !isShowingToast, let window = store.state.toastWindowID else { return true }
      let keys = quitItem.keyEquivalent.isEmpty ? "Quit" : ShortcutsPane.keys(quitItem)
      store.send(.windows(.element(id: window, action: .showToast("\(keys) again to quit", duration: .seconds(2)))))
      pending = store.windows[id: window]?.toast.map { (window, $0.id) }
      return false
    }
  }
}
