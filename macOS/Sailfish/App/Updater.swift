import AppKit
import ComposableArchitecture
import Sparkle

// Sparkle checks the appcast hourly (its shortest interval) and whenever the app comes to the front a quarter hour
// or more after the last check, downloads updates in the background and installs them on quit. Install and
// Relaunch quits through NSApp.terminate(_:), so it tells the quit warning to stand aside.
final class Updater: NSObject, SPUUpdaterDelegate {
  private let willRelaunch: @MainActor () -> Void
  private let updateReady: @MainActor (String) -> Void
  private(set) var controller: SPUStandardUpdaterController!
  private static let foregroundCheckGap: TimeInterval = 15 * 60

  init(willRelaunch: @escaping @MainActor () -> Void, updateReady: @escaping @MainActor (String) -> Void) {
    self.willRelaunch = willRelaunch
    self.updateReady = updateReady
    super.init()
    controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(checkOnActivation), name: NSApplication.didBecomeActiveNotification, object: nil)
  }

  @objc private func checkOnActivation() {
    let updater = controller.updater
    if let last = updater.lastUpdateCheckDate, Date().timeIntervalSince(last) < Self.foregroundCheckGap { return }
    updater.checkForUpdatesInBackground()
  }

  // A downloaded update waits for quit; the sidebar's pill offers to install it now. Returning true keeps Sparkle
  // from also reminding with its own alert; it still installs on quit.
  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock: @escaping () -> Void
  ) -> Bool {
    MainActor.assumeIsolated {
      UpdateClient.ready = immediateInstallationBlock
      updateReady(item.displayVersionString)
    }
    return true
  }

  // Sparkle quits with a quit Apple event, which AppKit refuses while a window has a sheet; terminate(_:) does not.
  func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    MainActor.assumeIsolated(willRelaunch)
    NSAppleEventManager.shared().setEventHandler(
      self, andSelector: #selector(quit(_:reply:)), forEventClass: AEEventClass(kCoreEventClass),
      andEventID: AEEventID(kAEQuitApplication))
  }

  @objc private func quit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
    MainActor.assumeIsolated { NSApp.terminate(nil) }
  }
}

extension SharedKey where Self == InMemoryKey<String?>.Default {
  // The version of a downloaded update waiting to install, which the sidebar's pill shows until relaunch.
  static var readyUpdate: Self { Self[.inMemory("readyUpdate"), default: nil] }
}

// Installs the ready update and relaunches.
struct UpdateClient: Sendable {
  var install: @MainActor @Sendable () -> Void
}

extension UpdateClient: DependencyKey {
  @MainActor fileprivate static var ready: (() -> Void)?
  static let liveValue = Self { ready?() }
}

extension DependencyValues {
  var updates: UpdateClient {
    get { self[UpdateClient.self] }
    set { self[UpdateClient.self] = newValue }
  }
}
