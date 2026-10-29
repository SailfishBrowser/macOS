import AppKit
import ComposableArchitecture
@preconcurrency import EngineCore

extension Engine {
  // A navigation the user started in a Chromium page leaves for WebKit before its request does, when its URL opens
  // there: the tab switches on the next turn, with the request's body and referrer. A navigation the tab's choice
  // keeps in Chromium stays, so the load `switchEngine` makes there is never handed back.
  func webContents(_ contents: ECWebContents, shouldHandOffNavigation request: URLRequest) -> Bool {
    guard let tab = shownTab(of: contents), let url = request.url else { return false }
    @Shared(.siteEngines) var siteEngines
    let cause: NavigationCause = request.httpMethod == "POST" ? .form : .link
    guard pageEngine(for: url, from: .chromium, choice: choices[tab], cause: cause, siteEngines) == .webkit else {
      return false
    }
    Task { await switchEngine(tab, to: .webkit, request: request) }
    return true
  }
}
