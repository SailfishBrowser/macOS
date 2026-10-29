import ComposableArchitecture
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

extension SiteEngines {
  // The engine the site's own rule names, nil when it has none.
  func rule(for site: String) -> PageEngineKind? {
    rules.first { $0.host == site }?.engine
  }

  // Writes the site's rule, or removes it for nil.
  mutating func setRule(_ site: String, _ engine: PageEngineKind?) {
    guard let engine else { return rules.removeAll { $0.host == site } }
    if let index = rules.firstIndex(where: { $0.host == site }) {
      rules[index].engine = engine
    } else {
      rules.append(SiteRule(id: UUID(), host: site, engine: engine))
    }
  }

  // Typed text as a rule's host: lowercased, without scheme or path, as its registrable domain.
  static func site(from text: String) -> String {
    let text = text.trimmingCharacters(in: .whitespaces).lowercased()
    guard !text.isEmpty else { return "" }
    let host = URL(string: text.contains("://") ? text : "https://" + text)?.host() ?? text
    return ECEngine.registrableDomain(forHost: host)
  }
}

extension Engine {
  // The engine "Open Page in" shows the tab's page in: the other one, for a web page.
  func otherEngine(_ tab: UUID) -> PageEngineKind? {
    guard let engine = shownEngine(tab), let scheme = page(tab)?.url?.scheme, scheme == "http" || scheme == "https"
    else { return nil }
    return engine == .chromium ? .webkit : .chromium
  }

  // Writes or removes the rule for the site of the tab's page, which then shows in the engine the site opens in.
  func setEngine(_ engine: PageEngineKind?, forSiteOf url: URL, in tab: UUID) {
    @Shared(.siteEngines) var siteEngines
    $siteEngines.withLock { $0.setRule(siteOf(url), engine) }
    guard let shown = shownEngine(tab) else { return }
    let opens = pageEngine(for: url, from: shown, choice: nil, cause: .typed, siteEngines)
    if opens != shown {
      Task { await reopen(tab, in: opens) }
    }
  }
}
