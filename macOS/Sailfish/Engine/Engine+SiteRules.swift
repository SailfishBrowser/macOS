@preconcurrency import EngineCore
import Foundation

extension PageEngineKind {
  var name: String {
    switch self {
    case .chromium: "Chromium"
    case .webkit: "WebKit"
    }
  }
}

extension Engine {
  // The engine "Open Page in" shows the tab's page in: the other one, for a web page.
  func otherEngine(_ tab: UUID) -> PageEngineKind? {
    guard let engine = shownEngine(tab), let scheme = page(tab)?.url?.scheme, scheme == "http" || scheme == "https"
    else { return nil }
    return engine == .chromium ? .webkit : .chromium
  }
}
