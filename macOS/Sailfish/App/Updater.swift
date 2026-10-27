import AppKit
import Sparkle

// Sparkle checks the appcast daily, downloads updates in the background and installs them on quit. Install and
// Relaunch quits through NSApp.terminate(_:), so it tells the quit warning to stand aside.
final class Updater: NSObject, SPUUpdaterDelegate {
  private let willRelaunch: @MainActor () -> Void
  private(set) var controller: SPUStandardUpdaterController!

  init(willRelaunch: @escaping @MainActor () -> Void) {
    self.willRelaunch = willRelaunch
    super.init()
    controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
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
