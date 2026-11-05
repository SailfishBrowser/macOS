import AppKit
import ComposableArchitecture
@preconcurrency import EngineCore
import Network

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // "Always use secure connections": Chrome's HTTPS-First strict mode in every profile, and its rules in WebKit pages.
  static var httpsOnly: Self { Self[.appStorage("httpsOnly"), default: false] }
}

extension SharedKey where Self == FileStorageKey<[Profile.ID: [String]]>.Default {
  // The hosts each profile's WebKit pages continued to over http.
  static var httpHosts: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "HTTPHosts.json")), default: [:]]
  }
}

extension Engine {
  // Chromium pages: Chrome's https_only_mode_enabled pref, which an incognito context reads through from its profile.
  func applyHTTPSOnly(_ context: ECBrowserContext) {
    @Shared(.httpsOnly) var httpsOnly
    context.httpsOnlyModeEnabled = httpsOnly
  }

  func httpsOnlyDidChange() {
    contexts.values.forEach(applyHTTPSOnly)
  }

  // WebKit pages, as Chrome's strict mode: a main-frame http load goes over https unless its host is this device or
  // the user continued to it in this profile (or in this incognito session).
  func upgradesToHTTPS(_ url: URL, profile: UUID, incognito: Bool) -> Bool {
    @Shared(.httpsOnly) var httpsOnly
    @Shared(.httpHosts) var httpHosts
    guard httpsOnly, url.scheme?.lowercased() == "http", let host = url.host(), !Self.isThisDevice(host) else {
      return false
    }
    let allowed = incognito ? incognitoHTTPHosts[profile, default: []] : Set(httpHosts[profile, default: []])
    return !allowed.contains(host)
  }

  private static func isThisDevice(_ host: String) -> Bool {
    if let address = IPv4Address(host) { return address.isLoopback }
    if let address = IPv6Address(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) {
      return address.isLoopback
    }
    return host == "localhost" || host.hasSuffix(".localhost")
  }

  // An http page a WebKit page could not load over https, asked as Chrome asks; Continue to Site loads it over http
  // and remembers its host.
  func webKitPage(_ page: WebKitPage, cannotUpgrade url: URL) {
    if defers(page, { self.webKitPage(page, cannotUpgrade: url) }) { return }
    guard let tab = tab(of: page), let host = url.host() else { return }
    let alert = NSAlert()
    alert.messageText = "\(host) doesn’t support a secure connection with HTTPS"
    alert.addButton(withTitle: "Go Back")
    alert.addButton(withTitle: "Continue to Site")
    present(alert.window, for: tab, { alert.beginSheetModal(for: $0, completionHandler: $1) }) { [weak page] response in
      guard response == .alertSecondButtonReturn, let page else { return }
      self.allowHTTP(host, profile: page.profile, incognito: page.incognito)
      page.load(URLRequest(url: url))
    }
  }

  private func allowHTTP(_ host: String, profile: UUID, incognito: Bool) {
    if incognito {
      incognitoHTTPHosts[profile, default: []].insert(host)
      return
    }
    @Shared(.httpHosts) var httpHosts
    $httpHosts.withLock { $0[profile, default: []].append(host) }
  }

  func forgetHTTPHosts(_ profile: UUID) {
    @Shared(.httpHosts) var httpHosts
    $httpHosts.withLock { $0[profile] = nil }
  }
}
