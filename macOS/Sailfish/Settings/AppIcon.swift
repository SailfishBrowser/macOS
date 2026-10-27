import AppKit

// The app icons Settings offers. The Original is the bundle's app icon (scripts/make-icon.swift); the others are
// recoloured Sailfish fins, AppIcon-<rawValue>.icns from scripts/make-alt-icons.swift. The Dock tile plug-in draws
// the chosen one, saved under `defaultsKey`, while the app is not running, and leaves the bundle's icon for the
// Original.
enum AppIcon: String, CaseIterable {
  case original, midnight, ocean, sunset, seafoam, gold, outline, monoLight, monoDark

  static let defaultsKey = "appIcon"

  var name: String {
    switch self {
    case .original: "The Original Sailfish"
    case .midnight: "Midnight"
    case .ocean: "Ocean"
    case .sunset: "Sunset"
    case .seafoam: "Seafoam"
    case .gold: "Gold"
    case .outline: "Outline"
    case .monoLight: "Mono Light"
    case .monoDark: "Mono Dark"
    }
  }

  // `app` is the Sailfish bundle, which the Dock tile plug-in passes since it runs inside the Dock.
  func image(in app: Bundle = .main) -> NSImage {
    if self == .original {
      return NSImage(named: "AppIcon")!
    }
    return NSImage(contentsOf: app.url(forResource: "AppIcon-\(rawValue)", withExtension: "icns")!)!
  }
}
