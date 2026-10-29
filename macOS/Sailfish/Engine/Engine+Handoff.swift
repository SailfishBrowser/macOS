import AppKit
import ComposableArchitecture
@preconcurrency import EngineCore
import WebKit

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

  // A link under the pointer in a Chromium page that would open in WebKit starts WebKit for the tab's store.
  func warmWebKit(_ tab: UUID, for link: URL) {
    guard let profile = tabProfiles[tab] else { return }
    @Shared(.siteEngines) var siteEngines
    guard pageEngine(for: link, from: .chromium, choice: choices[tab], cause: .link, siteEngines) == .webkit else {
      return
    }
    WebKitStores.warm(profile: profile, incognito: incognitoTabs.contains(tab))
  }
}

extension WebKitStores {
  private struct Key: Hashable {
    let profile: UUID
    let incognito: Bool
  }

  // Each store's hidden page, kept until the store's first page exists, and the stores that have had one.
  private static var warmViews: [Key: WKWebView] = [:]
  private static var opened: Set<Key> = []

  // Starts WebKit and the store's processes with a hidden page on about:blank, so the store's first page opens
  // fast. Nothing once the store has had a page.
  static func warm(profile: UUID, incognito: Bool) {
    let key = Key(profile: profile, incognito: incognito)
    guard warmViews[key] == nil, !opened.contains(key) else { return }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store(profile: profile, incognito: incognito)
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
    view.load(URLRequest(url: URL(string: "about:blank")!))
    warmViews[key] = view
  }

  // The store's first page exists, so its hidden page goes.
  static func pageOpened(profile: UUID, incognito: Bool) {
    let key = Key(profile: profile, incognito: incognito)
    opened.insert(key)
    warmViews[key] = nil
  }

  // An incognito session ended, so the next one's store starts cold.
  static func dropIncognitoWarmView(profile: UUID) {
    let key = Key(profile: profile, incognito: true)
    opened.remove(key)
    warmViews[key] = nil
  }
}
