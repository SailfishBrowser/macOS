import AppKit

// Draws the icon chosen in Settings on the app's Dock tile while the app is not running.
@objc(DockTilePlugIn)
final class DockTilePlugIn: NSObject, NSDockTilePlugIn {
  private var observer: NSObjectProtocol?

  func setDockTile(_ dockTile: NSDockTile?) {
    observer.map(DistributedNotificationCenter.default().removeObserver)
    observer = nil
    guard let dockTile else { return }
    // Contents/PlugIns/DockTile.docktileplugin in the app.
    let app = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundle = Bundle(url: app)!
    let id = bundle.bundleIdentifier!
    let update = {
      CFPreferencesAppSynchronize(id as CFString)
      let name = CFPreferencesCopyAppValue(AppIcon.defaultsKey as CFString, id as CFString) as? String
      let icon = name.flatMap(AppIcon.init) ?? .original
      dockTile.contentView = icon == .original ? nil : NSImageView(image: icon.image(in: bundle))
      dockTile.display()
    }
    update()
    observer = DistributedNotificationCenter.default().addObserver(
      forName: .init(id + "." + AppIcon.defaultsKey), object: nil, queue: .main) { _ in update() }
  }
}
