import ComposableArchitecture
import Foundation

enum PageEngineKind: String, Codable, Sendable {
  case chromium, webkit
}

// What started a navigation. Only the user's own (typed, link, form, newTab) can change a tab's engine, and a restore
// of a Chromium page, which opens where the table puts its site.
enum NavigationCause: Sendable {
  case typed, link, form, newTab, popup, redirect, script, history, reload, restore
}

// A streaming service: the entries that open in WebKit, and the sign-in entries that render in whichever engine
// reached them. An entry is a host, matching it and its subdomains, optionally followed by a path prefix.
struct SiteGroup: Sendable {
  let name: String
  let webKit: [String]
  let signIn: [String]
}

struct SiteRule: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var host: String
  var engine: PageEngineKind
}

// The engine a tab was last switched to and the registrable domain it was switched for, held while the tab's shown
// page stays on that site.
struct EngineChoice: Equatable, Sendable {
  let engine: PageEngineKind
  let site: String
}

struct SiteEngines: Codable, Equatable, Sendable {
  var streamingSitesInWebKit = true
  // In the order the Settings sheet lists them; the first that matches wins.
  var rules: [SiteRule] = []

  static let groups: [SiteGroup] = [
    SiteGroup(name: "Netflix", webKit: ["netflix.com"], signIn: []),
    SiteGroup(name: "Disney+", webKit: ["disneyplus.com"], signIn: []),
    SiteGroup(name: "Hulu", webKit: ["hulu.com"], signIn: []),
    SiteGroup(
      name: "Prime Video", webKit: ["primevideo.com"] + amazon.map { $0 + "/gp/video" },
      signIn: amazon.map { $0 + "/ap" }),
    SiteGroup(name: "Apple TV+", webKit: ["tv.apple.com"], signIn: ["idmsa.apple.com", "appleid.apple.com"]),
    SiteGroup(name: "Apple Music", webKit: ["music.apple.com"], signIn: ["idmsa.apple.com", "appleid.apple.com"]),
    SiteGroup(name: "Spotify", webKit: ["open.spotify.com"], signIn: ["accounts.spotify.com"]),
    SiteGroup(name: "HBO Max", webKit: ["hbomax.com", "max.com"], signIn: []),
    SiteGroup(name: "Paramount+", webKit: ["paramountplus.com"], signIn: []),
    SiteGroup(name: "Peacock", webKit: ["peacocktv.com"], signIn: []),
    SiteGroup(name: "Crunchyroll", webKit: ["crunchyroll.com"], signIn: []),
    SiteGroup(name: "JioHotstar", webKit: ["hotstar.com", "jiohotstar.com"], signIn: []),
    SiteGroup(name: "Tencent Video", webKit: ["v.qq.com"], signIn: ["graph.qq.com", "ptlogin2.qq.com"]),
  ]

  private static let amazon = [
    "amazon.com", "amazon.co.uk", "amazon.de", "amazon.co.jp", "amazon.ca", "amazon.com.au", "amazon.fr",
    "amazon.it", "amazon.es", "amazon.in",
  ]
}

extension SharedKey where Self == FileStorageKey<SiteEngines>.Default {
  static var siteEngines: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "SiteEngines.json")), default: SiteEngines()]
  }
}

// The engine a navigation to `url` renders in, given the engine of the page it starts from (nil for a new tab) and
// the tab's recorded choice.
func pageEngine(
  for url: URL, from current: PageEngineKind?, choice: EngineChoice?, cause: NavigationCause, _ settings: SiteEngines
) -> PageEngineKind {
  guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
    let host = url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
  else { return .chromium }
  switch cause {
  case .redirect, .script, .history, .reload, .popup:
    return current ?? .chromium
  case .restore:
    if current == .webkit { return .webkit }
  case .typed, .link, .form, .newTab:
    break
  }
  if let choice, host.isWithin(choice.site) {
    return choice.engine
  }
  if let rule = settings.rules.first(where: { host.isWithin($0.host.lowercased()) }) {
    return rule.engine
  }
  let path = url.path(percentEncoded: false)
  func listed(_ column: KeyPath<SiteGroup, [String]>) -> Bool {
    SiteEngines.groups.contains { $0[keyPath: column].contains { $0.matches(host: host, path: path) } }
  }
  if settings.streamingSitesInWebKit, listed(\.webKit) {
    return .webkit
  }
  if listed(\.signIn) {
    return cause == .newTab ? .chromium : current ?? .chromium
  }
  return .chromium
}

extension String {
  // Whether this host is `domain` or one of its subdomains.
  fileprivate func isWithin(_ domain: String) -> Bool {
    self == domain || hasSuffix("." + domain)
  }

  // A site table entry, "host" or "host/path", against a URL's host and path; the path matches whole segments.
  fileprivate func matches(host: String, path: String) -> Bool {
    let parts = split(separator: "/", maxSplits: 1)
    guard host.isWithin(String(parts[0])) else { return false }
    guard parts.count == 2 else { return true }
    let prefix = "/" + parts[1]
    return path == prefix || path.hasPrefix(prefix + "/")
  }
}
