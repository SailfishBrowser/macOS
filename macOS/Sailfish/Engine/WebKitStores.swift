import Foundation
import WebKit

// Each profile's WebKit website data, and the configuration WebKit pages are made with.
@MainActor enum WebKitStores {
  private static var stores: [UUID: WKWebsiteDataStore] = [:]
  // One per profile's incognito session, until the session ends.
  private static var incognitoStores: [UUID: WKWebsiteDataStore] = [:]

  // The major and minor version of the installed Safari, which the user agent claims, as Safari's own does.
  static let safariVersion: String = {
    let bundles = ["/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"]
    let version = bundles.lazy.compactMap { Bundle(path: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
      .first
    guard let version else {
      return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? "26.0" : "18.6"
    }
    return (version.split(separator: ".") + ["0"]).prefix(2).joined(separator: ".")
  }()

  static func store(profile: UUID, incognito: Bool) -> WKWebsiteDataStore {
    if incognito {
      let store = incognitoStores[profile] ?? .nonPersistent()
      incognitoStores[profile] = store
      return store
    }
    let store = stores[profile] ?? WKWebsiteDataStore(forIdentifier: profile)
    stores[profile] = store
    return store
  }

  // Ends the profile's incognito session, so the next one starts with a fresh store.
  static func dropIncognitoStore(profile: UUID) {
    incognitoStores[profile] = nil
  }

  // A new configuration on the profile's store, with the page scripts installed. Each page adds itself as the
  // `sailfish` message handler of its configuration's content controller.
  static func configuration(profile: UUID, incognito: Bool) -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store(profile: profile, incognito: incognito)
    // Plain http loads, as in Safari (Info.plist exempts web content from App Transport Security), and a host known
    // to serve https is upgraded to it.
    configuration.upgradeKnownHostsToHTTPS = true
    configuration.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.allowsAirPlayForMediaPlayback = true
    configuration.preferences.isElementFullscreenEnabled = true
    configuration.preferences.isFraudulentWebsiteWarningEnabled = false
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let controller = configuration.userContentController
    controller.addUserScript(
      WKUserScript(
        source: WebKitPageScript.isolated, injectionTime: .atDocumentStart, forMainFrameOnly: false,
        in: WebKitPageScript.world))
    controller.addUserScript(
      WKUserScript(source: WebKitPageScript.pageWorld, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    return configuration
  }
}
