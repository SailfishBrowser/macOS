import AppKit
@preconcurrency import EngineCore
import WebKit

// A WebKit page's visit to one URL, written to Chromium's history once its title settles, and the icon written for
// it.
struct WebKitVisit {
  let url: URL
  let profile: UUID
  let committed: ContinuousClock.Instant
  var title: String
  var isRecorded = false
  var icon: URL?
  var write: Task<Void, Never>?
}

// WebKit pages' history and favicons go into the profile's Chromium history, so history, autocomplete and the saved
// favicons of unloaded tabs include them.
extension Engine {
  // Chromium adds a visit at commit and its title as the page sets it, for up to 5 seconds; one call does both here,
  // so the visit waits until the title has not changed for 1.5 seconds, and no longer than those 5 seconds. A new URL
  // in the page, by a load or by the page's own history, is a new visit. Incognito pages record nothing.
  func recordVisit(_ tab: UUID, _ page: WebKitPage) {
    guard !incognitoTabs.contains(tab), let profile = tabProfiles[tab], let url = page.committedURL else { return }
    let title = page.webView.title ?? ""
    guard let visit = page.visit, visit.url == url else {
      page.visit = WebKitVisit(url: url, profile: profile, committed: .now, title: title)
      return scheduleVisit(page)
    }
    if visit.isRecorded {
      return writeFavicon(page)
    }
    guard visit.title != title else { return }
    page.visit?.title = title
    scheduleVisit(page)
  }

  // A visit is written even when its page closes or moves on first, as Chromium's is at commit.
  private func scheduleVisit(_ page: WebKitPage) {
    guard let visit = page.visit else { return }
    visit.write?.cancel()
    let delay: Duration = min(.seconds(1.5), max(.zero, .seconds(5) - visit.committed.duration(to: .now)))
    page.visit?.write = Task { [weak self, weak page] in
      guard (try? await Task.sleep(for: delay)) != nil, let self, let context = self.contexts[visit.profile] else { return }
      context.addVisit(to: visit.url, title: visit.title)
      guard let page, page.visit?.url == visit.url else { return }
      page.visit?.isRecorded = true
      self.writeFavicon(page)
    }
  }

  // The page's icon, once its visit is written, the page has loaded and the icon it lists has been fetched, so a page
  // never gets the icon of the one before it.
  private func writeFavicon(_ page: WebKitPage) {
    guard let visit = page.visit, visit.isRecorded, !page.webView.isLoading, let icon = page.faviconURL,
      icon == page.iconURL, icon != visit.icon, let image = page.favicon, let context = contexts[visit.profile]
    else { return }
    context.setFavicon(image, iconURL: icon, forPageURL: visit.url)
    page.visit?.icon = icon
  }
}

// WebKit pages' camera and microphone decisions live in the profile's Chromium site settings, keyed by origin, so
// Site Controls and Chromium pages of the site share them.
extension Engine {
  // The only permissions WebKit asks Sailfish for.
  static let capturePermissions: Set<String> = ["camera_stream", "mic_stream"]

  // A decision stored for the origin answers at once, a block of either one denying; otherwise the undecided ones are
  // asked with Chromium's popover and wording, and the answer is stored.
  func webKitPage(
    _ page: WebKitPage, requestsCapture type: WKMediaCaptureType, origin: WKSecurityOrigin,
    decision: @escaping @MainActor (WKPermissionDecision) -> Void
  ) {
    if defers(page, { self.webKitPage(page, requestsCapture: type, origin: origin, decision: decision) }) { return }
    guard let tab = tab(of: page), let context = tabContexts[tab],
      let site = Self.origin(origin.protocol, origin.host, origin.port)
    else { return decision(.deny) }
    let keys = [type == .microphone ? nil : "camera_stream", type == .camera ? nil : "mic_stream"].compactMap { $0 }
    let decided = context.permissions(forOrigin: site).mapValues(\.boolValue)
    guard !keys.contains(where: { decided[$0] == false }) else { return decision(.deny) }
    let asks = keys.filter { decided[$0] == nil }
    guard !asks.isEmpty else { return decision(.grant) }
    permissionRequests[tab] = PermissionRequest(message: Self.permissionMessage(asks, site), isLocation: false) {
      [weak self] allowed in
      self?.permissionRequests[tab] = nil
      asks.forEach { context.setPermission($0, allowed: allowed, forOrigin: site) }
      decision(allowed ? .grant : .deny)
    }
  }

  // The page's origin's decided camera and microphone permissions.
  func sitePermissions(_ tab: UUID, _ page: WebKitPage) -> [String: Bool] {
    guard let context = tabContexts[tab], let site = page.committedURL.flatMap(Self.origin) else { return [:] }
    return context.permissions(forOrigin: site).mapValues(\.boolValue).filter { Self.capturePermissions.contains($0.key) }
  }

  // Blocking one stops its capture if the page has one running.
  func setSitePermission(_ tab: UUID, _ page: WebKitPage, _ key: String, allowed: Bool) {
    guard let context = tabContexts[tab], let site = page.committedURL.flatMap(Self.origin) else { return }
    context.setPermission(key, allowed: allowed, forOrigin: site)
    guard !allowed else { return }
    if key == "camera_stream" {
      page.webView.setCameraCaptureState(.none)
    } else {
      page.webView.setMicrophoneCaptureState(.none)
    }
  }

  private static func origin(_ url: URL) -> URL? {
    origin(url.scheme ?? "", url.host() ?? "", url.port ?? 0)
  }

  // An origin as Chromium's site settings take it, with no port for the scheme's default.
  private static func origin(_ scheme: String, _ host: String, _ port: Int) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = port == 0 ? nil : port
    return components.url
  }
}
