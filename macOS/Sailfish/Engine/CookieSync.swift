import Combine
import ComposableArchitecture
import CryptoKit
@preconcurrency import EngineCore
import OSLog
import WebKit

// Keeps the cookies of the site groups' domains, and of the user's WebKit sites, the same in a Chromium context and
// its profile's WebKit store, one sync per context. A ledger records, per cookie, what both stores last agreed on,
// which tells this sync's own writes from real changes and, after a time without sync, which side changed.
@MainActor final class CookieSync: NSObject, @preconcurrency ECCookieDelegate {
  private static var syncs: [ObjectIdentifier: CookieSync] = [:]
  // WebKit pages with a load in progress.
  private static var loadingPages: Set<ObjectIdentifier> = []
  private static let writes = DispatchQueue(label: "CookieLedger", qos: .utility)
  // Each site group's registrable domains.
  private static let siteGroups: [Set<String>] = SiteEngines.groups.map { group in
    Set((group.webKit + group.signIn).map { ECEngine.registrableDomain(forHost: String($0.prefix { $0 != "/" })) })
  }

  private let profile: UUID
  private let incognito: Bool
  private let context: ECBrowserContext
  private let dataStore: WKWebsiteDataStore
  private var store: WKHTTPCookieStore { dataStore.httpCookieStore }
  @Shared(.siteEngines) private var siteEngines
  private var ledger: [CookieKey: Agreed] = [:]
  private var ledgerLoaded = false
  // WebKit's cookies in scope as the last flush read them.
  private var snapshot: [CookieKey: HTTPCookie] = [:]
  // Chromium's changes applied to WebKit since the last flush, nil for a removal.
  private var chromiumChanges: [CookieKey: ECCookie?] = [:]
  // Chromium's changes reported while an operation runs, applied after it.
  private var pending: [(cookie: ECCookie, removed: Bool)] = []
  private var scope: [String] = []
  private var rules: AnyCancellable?
  private var operations: Task<Void, Never>?
  private(set) var isLive = false
  private var isBusy = false
  private var isEnded = false
  private var flushScheduled = false
  private var saveScheduled = false

  private init(profile: UUID, incognito: Bool, context: ECBrowserContext) {
    self.profile = profile
    self.incognito = incognito
    self.context = context
    dataStore = WebKitStores.store(profile: profile, incognito: incognito)
  }

  // The sync of the profile's context, or of its incognito one.
  static func shared(profile: UUID, incognito: Bool) -> CookieSync {
    let context = Engine.shared.loadedContext(profile, incognito)
    if let sync = syncs[ObjectIdentifier(context)] { return sync }
    let sync = CookieSync(profile: profile, incognito: incognito, context: context)
    syncs[ObjectIdentifier(context)] = sync
    return sync
  }

  // A WebKit page finished a load, whose responses may have set cookies: its store's sync flushes. WebKit's cookie
  // observer cannot tell instead, as it stays silent once the store is read or written after it is added.
  static func pageDidUpdate(_ page: WebKitPage) {
    let id = ObjectIdentifier(page)
    if page.webView.isLoading {
      loadingPages.insert(id)
    } else if loadingPages.remove(id) != nil {
      sync(of: page)?.scheduleFlush()
    }
  }

  // A WebKit page closed; its store's sync closes unless another page of the store is alive by then.
  static func pageDidClose(_ page: WebKitPage) {
    loadingPages.remove(ObjectIdentifier(page))
    guard let sync = sync(of: page) else { return }
    Task { await sync.close() }
  }

  private static func sync(of page: WebKitPage) -> CookieSync? {
    let store = page.webView.configuration.websiteDataStore
    return syncs.values.first { $0.dataStore === store }
  }

  // The context is about to close, discarding or deleting its cookies: its sync stops without a last flush.
  static func end(_ context: ECBrowserContext) {
    syncs.removeValue(forKey: ObjectIdentifier(context))?.end(saving: false)
  }

  // Quitting: every sync stops and saves its ledger, and the next open reconciles what was not flushed.
  static func endAll() {
    syncs.values.forEach { $0.end(saving: true) }
    syncs = [:]
  }

  // Reconciles both stores once, then keeps them in step until the store's last page closes.
  func open() async {
    await run { [self] in
      guard !isLive else { return }
      if !ledgerLoaded, let file = ledgerFile {
        ledger = await Task.detached { Self.readLedger(file) }.value
      }
      ledgerLoaded = true
      startObserving()
      await reconcile()
    }
  }

  // Applies Chromium's cookies for the URL's site groups to WebKit, so a cookie the page being left just set is
  // there before WebKit loads the URL.
  func drain(for url: URL) async {
    await run { [self] in
      let domains = groupDomains(of: url)
      guard isLive, !domains.isEmpty else { return }
      let cookies = await chromiumCookies(Array(domains))
      guard !isEnded else { return }
      var writes: [HTTPCookie] = []
      for cookie in cookies where ledger[cookie.key] != cookie.agreed {
        guard let copy = webKitCookie(cookie) else { continue }
        ledger[cookie.key] = cookie.agreed
        writes.append(copy)
      }
      let present = Set(cookies.map(\.key))
      let removed = ledger.keys.filter { !present.contains($0) && Self.isUnder($0.domain, Array(domains)) }
      removed.forEach { ledger[$0] = nil }
      await setInWebKit(writes, removing: removed)
      saveLedger()
    }
  }

  // Reads WebKit's store and applies what changed since the last read to Chromium.
  func flush() async {
    await run { [self] in
      guard isLive else { return }
      await flushNow()
    }
  }

  // Flushes and stops, once no page of the store is alive.
  func close() async {
    await run { [self] in
      guard isLive, !hasLivePages else { return }
      await flushNow()
      guard !isEnded else { return }
      stopObserving()
      saveLedger()
    }
  }

  func browserContext(_ context: ECBrowserContext, cookieDidChange cookie: ECCookie, removed: Bool) {
    guard isLive else { return }
    guard !isBusy else { return pending.append((cookie, removed)) }
    apply(cookie, removed: removed)
  }

  // A flush 250 ms on, which reads the whole store, as nothing says which cookie changed.
  private func scheduleFlush() {
    guard isLive, !flushScheduled else { return }
    flushScheduled = true
    Task {
      try? await Task.sleep(for: .milliseconds(250))
      flushScheduled = false
      await flush()
    }
  }

  // Runs operations one at a time; Chromium's changes reported meanwhile wait until the operation ends.
  private func run(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
    let previous = operations
    let task = Task { @MainActor [self] in
      await previous?.value
      guard !isEnded else { return }
      isBusy = true
      await operation()
      isBusy = false
      let changes = pending
      pending = []
      guard isLive, !isEnded else { return }
      changes.forEach { apply($0.cookie, removed: $0.removed) }
    }
    operations = task
    await task.value
  }

  private func startObserving() {
    isLive = true
    scope = currentScope()
    context.cookieDelegate = self
    context.observedCookieDomains = scope
    rules = $siteEngines.publisher.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.updateScope() }
    }
  }

  private func stopObserving() {
    isLive = false
    rules = nil
    context.observedCookieDomains = []
    context.cookieDelegate = nil
    snapshot = [:]
    chromiumChanges = [:]
    pending = []
  }

  private func end(saving: Bool) {
    isEnded = true
    if isLive {
      stopObserving()
    }
    // Waits for the ledger writes already queued, so none lands after the context's data is gone.
    guard saving, let file = ledgerFile, ledgerLoaded else {
      Self.writes.sync {}
      return
    }
    let data = encodedLedger
    Self.writes.sync { Self.writeLedger(data, to: file) }
  }

  // The rules changed while live: Chromium reports changes under the new set of domains.
  private func updateScope() {
    guard isLive else { return }
    let scope = currentScope()
    guard scope != self.scope else { return }
    self.scope = scope
    context.observedCookieDomains = scope
  }

  // A Chromium change that is not this sync's own write goes to WebKit.
  private func apply(_ cookie: ECCookie, removed: Bool) {
    let key = cookie.key
    if removed {
      guard ledger.removeValue(forKey: key) != nil else { return }
      chromiumChanges[key] = .some(nil)
      store.delete(key.webKitCookie)
    } else {
      guard ledger[key] != cookie.agreed, let copy = webKitCookie(cookie) else { return }
      ledger[key] = cookie.agreed
      chromiumChanges[key] = cookie
      store.setCookie(copy)
    }
    saveLedger()
  }

  // Once per live session, before the store's first page loads: a cookie both stores have that differs is copied
  // from the side that differs from the ledger, Chromium winning when neither or both do; a cookie one store lacks
  // is deleted from the other if the ledger has it and it is persistent, and copied otherwise.
  private func reconcile() async {
    let chromium = Dictionary(await chromiumCookies(scope).map { ($0.key, $0) }) { $1 }
    guard !isEnded else { return }
    let webKit = await webKitCookies()
    guard !isEnded else { return }
    var agreed: [CookieKey: Agreed] = [:]
    var toWebKit: [HTTPCookie] = []
    var removeFromWebKit: [CookieKey] = []
    var toChromium: [(CookieKey, ECCookie)] = []
    var removeFromChromium: [ECCookie] = []
    for key in Set(chromium.keys).union(webKit.keys) {
      let known = ledger[key]
      switch (chromium[key], webKit[key]) {
      case let (chromium?, webKit?):
        if chromium.agreed == known, !webKit.matches(known) {
          agreed[key] = Agreed(webKit, sameSite: chromium.sameSite)
          toChromium.append((key, chromiumCookie(webKit, sameSite: chromium.sameSite)))
        } else {
          agreed[key] = chromium.agreed
          if !webKit.equals(chromium), let copy = webKitCookie(chromium) {
            toWebKit.append(copy)
          }
        }
      case let (chromium?, nil):
        if known != nil, chromium.expiry != nil {
          removeFromChromium.append(chromium)
        } else if let copy = webKitCookie(chromium) {
          agreed[key] = chromium.agreed
          toWebKit.append(copy)
        }
      case let (nil, webKit?):
        if known != nil, webKit.expiresDate != nil {
          removeFromWebKit.append(key)
        } else {
          agreed[key] = Agreed(webKit, sameSite: webKit.chromiumSameSite)
          toChromium.append((key, chromiumCookie(webKit, sameSite: webKit.chromiumSameSite)))
        }
      case (nil, nil):
        break
      }
    }
    ledger = agreed
    await setInWebKit(toWebKit, removing: removeFromWebKit)
    await setInChromium(toChromium, removing: removeFromChromium)
    guard !isEnded else { return }
    snapshot = await webKitCookies()
    // A cookie WebKit refused leaves the ledger, so the next reconcile copies it again rather than deleting it.
    for key in toWebKit.map(\.key) where snapshot[key] == nil {
      ledger[key] = nil
    }
    saveLedger()
  }

  // What WebKit changed since the last read goes to Chromium, unless Chromium changed the same cookie meanwhile and
  // no shown WebKit page is on that cookie's site group, in which case Chromium's change is applied to WebKit again.
  private func flushNow() async {
    let cookies = await webKitCookies()
    guard !isEnded else { return }
    var shown: [String]?
    func chromiumWins(_ key: CookieKey) -> Bool {
      guard chromiumChanges[key] != nil else { return false }
      let domains = shown ?? shownDomains()
      shown = domains
      return !Self.isUnder(key.domain, domains)
    }
    var toWebKit: [HTTPCookie] = []
    var removeFromWebKit: [CookieKey] = []
    var toChromium: [(CookieKey, ECCookie)] = []
    var removeFromChromium: [ECCookie] = []
    func reassert(_ key: CookieKey) {
      switch chromiumChanges[key] {
      case let cookie??:
        if let copy = webKitCookie(cookie) {
          toWebKit.append(copy)
        }
      default:
        removeFromWebKit.append(key)
      }
    }
    for (key, cookie) in cookies where !(snapshot[key]?.equals(cookie) ?? false) && !cookie.matches(ledger[key]) {
      if chromiumWins(key) {
        reassert(key)
        continue
      }
      let sameSite = ledger[key]?.sameSite ?? cookie.chromiumSameSite
      ledger[key] = Agreed(cookie, sameSite: sameSite)
      toChromium.append((key, chromiumCookie(cookie, sameSite: sameSite)))
    }
    for key in snapshot.keys where cookies[key] == nil && ledger[key] != nil && Self.isUnder(key.domain, scope) {
      if chromiumWins(key) {
        reassert(key)
        continue
      }
      ledger[key] = nil
      removeFromChromium.append(key.chromiumCookie)
    }
    snapshot = cookies
    chromiumChanges = [:]
    await setInWebKit(toWebKit, removing: removeFromWebKit)
    await setInChromium(toChromium, removing: removeFromChromium)
    saveLedger()
  }

  private func chromiumCookies(_ domains: [String]) async -> [ECCookie] {
    await withCheckedContinuation { continuation in
      // The engine answers on the main thread, where this sync runs.
      context.cookies(forDomains: domains) { cookies in
        nonisolated(unsafe) let cookies = cookies
        continuation.resume(returning: cookies)
      }
    }
  }

  // WebKit's unexpired, unpartitioned cookies in scope.
  private func webKitCookies() async -> [CookieKey: HTTPCookie] {
    let now = Date.now
    let cookies = await store.allCookies().filter {
      !$0.isPartitioned && Self.isUnder($0.domain, scope) && ($0.expiresDate.map { $0 > now } ?? true)
    }
    return Dictionary(cookies.map { ($0.key, $0) }) { $1 }
  }

  // Sent all at once: WebKit applies them in order, and awaiting each would hold the next for a round trip to its
  // network process.
  private func setInWebKit(_ cookies: [HTTPCookie], removing keys: [CookieKey]) async {
    guard !cookies.isEmpty || !keys.isEmpty else { return }
    await withCheckedContinuation { continuation in
      let group = DispatchGroup()
      for cookie in cookies {
        group.enter()
        store.setCookie(cookie) { group.leave() }
      }
      for key in keys {
        group.enter()
        store.delete(key.webKitCookie) { group.leave() }
      }
      group.notify(queue: .main) { continuation.resume() }
    }
  }

  // One cookie per call, so a cookie Chromium refuses leaves the ledger, and the next reconcile copies it again
  // rather than deleting it from WebKit.
  private func setInChromium(_ cookies: [(CookieKey, ECCookie)], removing removed: [ECCookie]) async {
    for (key, cookie) in cookies {
      guard !isEnded else { return }
      let count = await withCheckedContinuation { continuation in
        context.import([cookie]) { continuation.resume(returning: $0) }
      }
      if count == 0 {
        ledger[key] = nil
      }
    }
    guard !isEnded, !removed.isEmpty else { return }
    _ = await withCheckedContinuation { continuation in
      context.delete(removed) { continuation.resume(returning: $0) }
    }
  }

  private var hasLivePages: Bool {
    Engine.shared.livePages.values.contains { ($0 as? WebKitPage)?.webView.configuration.websiteDataStore === dataStore }
  }

  // The domains of the site groups that a shown WebKit page of this store is on.
  private func shownDomains() -> [String] {
    let engine = Engine.shared
    let sites = Set(
      engine.pageRecords.keys.compactMap { engine.page($0) as? WebKitPage }
        .filter { $0.webView.configuration.websiteDataStore === dataStore }
        .compactMap { $0.url.map { engine.siteOf($0) } })
    return Array(groups().filter { !$0.isDisjoint(with: sites) }.reduce(into: Set()) { $0.formUnion($1) })
  }

  // The site groups, and each WebKit rule's site as a group of its own.
  private func groups() -> [Set<String>] {
    Self.siteGroups
      + siteEngines.rules.filter { $0.engine == .webkit }.map {
        [ECEngine.registrableDomain(forHost: $0.host.lowercased())]
      }
  }

  private func currentScope() -> [String] {
    groups().reduce(into: Set()) { $0.formUnion($1) }.sorted()
  }

  private func groupDomains(of url: URL) -> Set<String> {
    let site = Engine.shared.siteOf(url)
    return groups().filter { $0.contains(site) }.reduce(into: Set()) { $0.formUnion($1) }
  }

  // Whether a cookie's domain is one of `domains` or under one.
  private static func isUnder(_ domain: String, _ domains: [String]) -> Bool {
    let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    return domains.contains { host == $0 || host.hasSuffix("." + $0) }
  }

  // The ledger is kept per profile on disk, and in memory only for incognito.
  private var ledgerFile: URL? {
    incognito ? nil : URL.dataDirectory.appending(path: "WebKit/\(profile.uuidString)/CookieLedger.json")
  }

  private var encodedLedger: Data {
    try! JSONEncoder().encode(ledger)
  }

  private func saveLedger() {
    guard let file = ledgerFile, !saveScheduled else { return }
    saveScheduled = true
    Task { [self] in
      saveScheduled = false
      guard !isEnded else { return }
      let data = encodedLedger
      Self.writes.async { Self.writeLedger(data, to: file) }
    }
  }

  private nonisolated static func readLedger(_ file: URL) -> [CookieKey: Agreed] {
    guard let data = try? Data(contentsOf: file) else { return [:] }
    do {
      return try JSONDecoder().decode([CookieKey: Agreed].self, from: data)
    } catch {
      Logger().error("Reading the cookie ledger failed: \(error)")
      return [:]
    }
  }

  private nonisolated static func writeLedger(_ data: Data, to file: URL) {
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: file, options: .atomic)
    } catch {
      Logger().error("Saving the cookie ledger failed: \(error)")
    }
  }
}

private struct CookieKey: Hashable, Codable {
  let name: String
  let domain: String
  let path: String

  // A cookie to delete this one with: WebKit and Chromium match it by name, domain and path.
  var webKitCookie: HTTPCookie {
    HTTPCookie(properties: [.name: name, .value: "", .domain: domain, .path: path])!
  }

  var chromiumCookie: ECCookie {
    ECCookie(
      name: name, value: "", domain: domain, path: path, creation: .now, expiry: nil, lastAccess: .now, secure: false,
      httpOnly: false, sameSite: -1)
  }
}

// What both stores last agreed a cookie was: a hash of its value, its expiry in whole seconds (nil for a session
// cookie), and Chromium's SameSite, which WebKit can hold only in part.
private struct Agreed: Codable, Equatable {
  let value: String
  let expiry: Int?
  let sameSite: Int

  init(value: String, expiry: Date?, sameSite: Int) {
    self.value = Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
    self.expiry = expiry.map { Int($0.timeIntervalSince1970.rounded(.down)) }
    self.sameSite = sameSite
  }

  init(_ cookie: HTTPCookie, sameSite: Int) {
    self.init(value: cookie.value, expiry: cookie.expiresDate, sameSite: sameSite)
  }
}

// Every key a WebKit cookie's properties carry, except a partitioned cookie's partition: the public keys, the raw
// "HttpOnly" WebKit reads, its creation time, and the raw value of macOS 15.2's setByJavaScript key.
private let knownCookieProperties = Set(
  [
    HTTPCookiePropertyKey.name, .value, .domain, .path, .secure, .expires, .discard, .comment, .commentURL, .version,
    .port, .maximumAge, .originURL, .sameSitePolicy,
  ].map(\.rawValue)
).union(["HttpOnly", "Created", "SetInJavaScript"])

// Expiries go across in whole seconds, as WebKit keeps them.
private func wholeSeconds(_ date: Date) -> Date {
  Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
}

extension ECCookie {
  fileprivate var key: CookieKey { CookieKey(name: name, domain: domain, path: path) }
  fileprivate var agreed: Agreed { Agreed(value: value, expiry: expiry, sameSite: sameSite) }
}

extension HTTPCookie {
  fileprivate var key: CookieKey { CookieKey(name: name, domain: domain, path: path) }

  // A partitioned cookie carries its partition under a key outside the known ones; Chromium's side skips them too.
  fileprivate var isPartitioned: Bool {
    (properties ?? [:]).keys.contains { !knownCookieProperties.contains($0.rawValue) }
  }

  // Chromium's SameSite for WebKit's: strict and lax map, and WebKit's absent one is unspecified.
  fileprivate var chromiumSameSite: Int {
    switch sameSitePolicy {
    case HTTPCookieStringPolicy.sameSiteStrict?: 2
    case HTTPCookieStringPolicy.sameSiteLax?: 1
    default: -1
    }
  }

  fileprivate func matches(_ agreed: Agreed?) -> Bool {
    guard let agreed else { return false }
    let own = Agreed(self, sameSite: agreed.sameSite)
    return own.value == agreed.value && own.expiry == agreed.expiry
  }

  fileprivate func equals(_ other: HTTPCookie) -> Bool {
    value == other.value && expiresDate.map(wholeSeconds) == other.expiresDate.map(wholeSeconds)
  }

  // The same value and expiry as Chromium's copy, with the SameSite WebKit can hold.
  fileprivate func equals(_ cookie: ECCookie) -> Bool {
    value == cookie.value && expiresDate.map(wholeSeconds) == cookie.expiry.map(wholeSeconds)
      && sameSitePolicy == webKitSameSite(cookie.sameSite)
  }
}

// WebKit's SameSite for Chromium's: strict and lax map, and none and unspecified are left off.
private func webKitSameSite(_ sameSite: Int) -> HTTPCookieStringPolicy? {
  switch sameSite {
  case 2: .sameSiteStrict
  case 1: .sameSiteLax
  default: nil
  }
}

private func webKitCookie(_ cookie: ECCookie) -> HTTPCookie? {
  var properties: [HTTPCookiePropertyKey: Any] = [
    .name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path,
  ]
  if let expiry = cookie.expiry {
    properties[.expires] = wholeSeconds(expiry)
  }
  if cookie.secure {
    properties[.secure] = "TRUE"
  }
  if cookie.httpOnly {
    properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
  }
  if let sameSite = webKitSameSite(cookie.sameSite) {
    properties[.sameSitePolicy] = sameSite
  }
  return HTTPCookie(properties: properties)
}

private func chromiumCookie(_ cookie: HTTPCookie, sameSite: Int) -> ECCookie {
  ECCookie(
    name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, creation: .now,
    expiry: cookie.expiresDate.map(wholeSeconds), lastAccess: .now, secure: cookie.isSecure,
    httpOnly: cookie.isHTTPOnly, sameSite: sameSite)
}

extension Engine {
  func cookieSync(_ tab: UUID) -> CookieSync? {
    tabProfiles[tab].map { CookieSync.shared(profile: $0, incognito: incognitoTabs.contains(tab)) }
  }

  // Before the tab changes engine: WebKit's changes reach Chromium before a Chromium page loads, and a WebKit page
  // loads once the store's sync is open and has Chromium's cookies for the URL.
  func syncCookies(_ tab: UUID, switchingTo engine: PageEngineKind, for url: URL) async {
    guard let sync = cookieSync(tab) else { return }
    switch engine {
    case .chromium:
      await sync.flush()
    case .webkit:
      // Opening reads every cookie in scope from Chromium, so only a sync already open drains.
      if sync.isLive {
        await sync.drain(for: url)
      } else {
        await sync.open()
      }
    }
  }

  // Before Back, Forward or a history entry shows the tab's page at `index`: a Chromium page shown in place of a
  // WebKit one gets WebKit's changes first, and a WebKit page made from its saved history waits for the sync to open.
  func syncCookies(_ tab: UUID, showing index: Int) async {
    guard let record = pageRecords[tab]?[index] else { return }
    switch record.engine {
    case .chromium where shownEngine(tab) == .webkit: await cookieSync(tab)?.flush()
    case .webkit where livePages[record.id] == nil: await cookieSync(tab)?.open()
    case .chromium, .webkit: break
    }
  }
}
