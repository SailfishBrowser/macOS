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

  // Each store's warm web view, kept for the store's first page, and the stores that have had a page.
  private static var warmViews: [Key: WebKitWebView] = [:]
  private static var opened: Set<Key> = []

  // Starts WebKit for the store with a page's web view, which the store's first page then takes: a script run in its
  // empty document starts the store's content process with the page script's world, its canvas starts the GPU
  // process, and reading the store's cookies starts the network process. Nothing once the store has had a page.
  static func warm(profile: UUID, incognito: Bool) {
    let key = Key(profile: profile, incognito: incognito)
    guard warmViews[key] == nil, !opened.contains(key) else { return }
    let view = WebKitWebView(profile: profile, incognito: incognito, configuration: nil)
    view.evaluateJavaScript(
      "document.createElement('canvas').getContext('2d').fillRect(0, 0, 1, 1)", in: nil, in: WebKitPageScript.world
    ) { _ in }
    view.configuration.websiteDataStore.httpCookieStore.getAllCookies { _ in }
    warmViews[key] = view
  }

  // The web view for the store's next page: the warm one for its first, when there is one.
  static func webView(profile: UUID, incognito: Bool) -> WebKitWebView {
    let key = Key(profile: profile, incognito: incognito)
    opened.insert(key)
    return warmViews.removeValue(forKey: key)
      ?? WebKitWebView(profile: profile, incognito: incognito, configuration: nil)
  }

  // The store's session ended or its profile was deleted, so its warm view goes and a next store starts cold.
  static func dropWarmView(profile: UUID, incognito: Bool) {
    let key = Key(profile: profile, incognito: incognito)
    opened.remove(key)
    warmViews[key] = nil
  }
}
