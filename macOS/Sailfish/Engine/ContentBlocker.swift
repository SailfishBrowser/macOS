import ComposableArchitecture
import CryptoKit
import Foundation
import OSLog
import WebKit

// Ad blocking in WebKit pages: uBlock Origin's default filter lists, converted into WebKit content rule lists and
// given to every WebKit page while "Block ads and trackers with uBlock Origin" is on. The lists start as the bundled
// uBlock Origin's copies and are fetched again on uBlock's schedule. They compile in the background and no page waits
// for them: a page made before they exist gets them from its next load.
@MainActor enum ContentBlocker {
  // Part of every compiled list's identifier; raising it when the converter's output changes compiles the lists again.
  nonisolated private static let converterVersion = 1
  private static let identifierPrefix = "ContentBlocker"
  // The lists compiled so far, on every live WebKit page while the setting is on.
  private(set) static var ruleLists: [WKContentRuleList] = [] {
    didSet { applyToLivePages() }
  }
  private static var task: Task<Void, Never>?

  // Looks up the compiled lists or compiles them, then fetches each filter list on uBlock Origin's schedule: checked 37
  // seconds after the lists are ready and every hour after that, each list fetched once its copy has expired. Does
  // nothing once started.
  static func start() {
    guard task == nil else { return }
    let root = URL(filePath: Engine.adBlocker)
    task = Task {
      var lists: FilterLists
      do {
        lists = try await Task.detached(priority: .utility) { try FilterLists(root: root) }.value
      } catch {
        return Logger().error("Filter lists not read: \(error)")
      }
      await compile(lists.texts)
      guard (try? await Task.sleep(for: .seconds(37))) != nil else { return }
      repeat {
        let fetched = await lists.fetchingDue()
        if fetched.texts != lists.texts {
          await compile(fetched.texts)
        }
        lists = fetched
      } while (try? await Task.sleep(for: .seconds(3600))) != nil
    }
  }

  static func stop() {
    task?.cancel()
    task = nil
  }

  // Gives the controller the compiled lists while the setting is on and takes them away while it is off; its page
  // follows from its next load.
  static func apply(to controller: WKUserContentController) {
    @Shared(.blocksAds) var blocksAds
    controller.removeAllContentRuleLists()
    guard blocksAds else { return }
    ruleLists.forEach(controller.add)
  }

  static func applyToLivePages() {
    for case let page as WebKitPage in Engine.shared.livePages.values {
      apply(to: page.webView.configuration.userContentController)
    }
  }

  // Looks up the lists compiled from these texts, or compiles them, and removes the ones compiled from other texts.
  private static func compile(_ texts: [String]) async {
    let store = WKContentRuleListStore.default()!
    let version = await Task.detached(priority: .utility) { digest(texts) }.value
    let prefix = "\(identifierPrefix).\(version)."
    let ours = (await store.availableIdentifiers() ?? []).filter { $0.hasPrefix(identifierPrefix + ".") }
    if let lists = await lookUp(ours.filter { $0.hasPrefix(prefix) }, prefix: prefix, in: store) {
      ruleLists = lists
    } else {
      let chunks = await Task.detached(priority: .utility) { encoded(rules(from: texts)) }.value
      // A first compile gives pages each list as it is ready; a recompile replaces the old lists at once.
      let replacing = !ruleLists.isEmpty
      var compiled: [WKContentRuleList] = []
      do {
        for (index, chunk) in chunks.enumerated() {
          let id = "\(prefix)\(index).\(chunks.count)"
          if let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: chunk) {
            compiled.append(list)
          }
          if !replacing {
            ruleLists = compiled
          }
        }
      } catch {
        return Logger().error("Content rules not compiled: \(error)")
      }
      ruleLists = compiled
    }
    for identifier in ours where !identifier.hasPrefix(prefix) {
      try? await store.removeContentRuleList(forIdentifier: identifier)
    }
  }

  // The stored lists of one compile, in order, when all of them are there and this WebKit can read them.
  private static func lookUp(
    _ identifiers: [String], prefix: String, in store: WKContentRuleListStore
  ) async -> [WKContentRuleList]? {
    let ordered = identifiers.indices.map { "\(prefix)\($0).\(identifiers.count)" }
    guard !identifiers.isEmpty, Set(ordered) == Set(identifiers) else { return nil }
    var lists: [WKContentRuleList] = []
    for identifier in ordered {
      guard let list = try? await store.contentRuleList(forIdentifier: identifier) else { return nil }
      lists.append(list)
    }
    return lists
  }

  nonisolated private static func digest(_ texts: [String]) -> String {
    var hash = SHA256()
    hash.update(data: Data("\(converterVersion)".utf8))
    texts.forEach { hash.update(data: Data($0.utf8)) }
    return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated private static func encoded(_ rules: (network: [[ContentRule]], cosmetic: [[ContentRule]])) -> [String] {
    (rules.network + rules.cosmetic).map { "[" + $0.map(\.json).joined(separator: ",") + "]" }
  }

  // Converts filter lists in uBlock Origin's syntax into chunks of content rules, network chunks and cosmetic chunks,
  // each within WebKit's limit. A filter outside the subset WebKit can express is skipped whole.
  nonisolated static func rules(from lists: [String]) -> (network: [[ContentRule]], cosmetic: [[ContentRule]]) {
    let lines = lists.flatMap(FilterSet.activeLines)
    let cancelled = Set(lines.compactMap(FilterSet.badfilterTarget))
    var filters = FilterSet()
    for line in lines where !cancelled.contains(line) {
      filters.add(line)
    }
    return (filters.networkChunks, filters.cosmeticChunks)
  }
}

// One rule of a WebKit content rule list.
struct ContentRule: Hashable, Sendable {
  struct Trigger: Hashable, Sendable {
    var urlFilter = ".*"
    var isCaseSensitive: Bool?
    var ifDomain: [String]?
    var unlessDomain: [String]?
    var resourceType: [String]?
    var loadType: [String]?
    var loadContext: [String]?
  }

  struct Action: Hashable, Sendable {
    var type: String
    var selector: String?
  }

  var trigger: Trigger
  var action: Action

  // The rule in WebKit's JSON format, written directly: an encoder's intermediate values would more than double the
  // memory a compile takes.
  var json: String {
    let trigger = Self.object([
      ("url-filter", Self.string(self.trigger.urlFilter)),
      ("url-filter-is-case-sensitive", self.trigger.isCaseSensitive.map(String.init)),
      ("if-domain", self.trigger.ifDomain.map(Self.array)),
      ("unless-domain", self.trigger.unlessDomain.map(Self.array)),
      ("resource-type", self.trigger.resourceType.map(Self.array)),
      ("load-type", self.trigger.loadType.map(Self.array)),
      ("load-context", self.trigger.loadContext.map(Self.array)),
    ])
    let action = Self.object([
      ("type", Self.string(self.action.type)), ("selector", self.action.selector.map(Self.string)),
    ])
    return #"{"trigger":\#(trigger),"action":\#(action)}"#
  }

  private static func object(_ members: [(name: String, value: String?)]) -> String {
    "{" + members.compactMap { member in member.value.map { "\"\(member.name)\":\($0)" } }.joined(separator: ",") + "}"
  }

  private static func array(_ strings: [String]) -> String {
    "[" + strings.map(string).joined(separator: ",") + "]"
  }

  private static func string(_ string: String) -> String {
    var json = "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": json += "\\\""
      case "\\": json += "\\\\"
      case _ where scalar.value < 0x20: json += String(format: "\\u%04x", scalar.value)
      default: json.unicodeScalars.append(scalar)
      }
    }
    return json + "\""
  }
}

// The default filter lists' texts: each list's last fetched copy in URL.dataDirectory/ContentBlocker, or else the
// bundled uBlock Origin's, with where and how often uBlock Origin fetches it.
struct FilterLists: Sendable {
  // The lists uBlock Origin enables by default, by their key in its assets.json.
  static let keys = [
    "ublock-filters", "ublock-badware", "ublock-privacy", "ublock-quick-fixes", "ublock-unbreak", "easylist",
    "easyprivacy", "urlhaus-1", "plowe-0",
  ]
  static let directory = URL.dataDirectory.appending(path: "ContentBlocker")
  private static let session = URLSession(configuration: .ephemeral)

  struct List: Sendable {
    let key: String
    var text: String
    // Where uBlock Origin fetches the list, in its order.
    let urls: [URL]
    // The days a copy stays current when its text names no expiry.
    let updateAfter: Double
    // When the saved copy was fetched; nil for the bundled copy, which is due at the first check.
    var fetched: Date?

    var isDue: Bool {
      fetched.map { Date.now.timeIntervalSince($0) >= expiry * 86400 } ?? true
    }

    // The days a copy stays current: its own Expires header, read as uBlock Origin reads it, or else the asset's.
    private var expiry: Double {
      let header = text.prefix(1024).split(whereSeparator: \.isNewline).lazy
        .map { $0.drop { "!# ".contains($0) }.lowercased() }
        .first { $0.hasPrefix("expires:") }
      guard let match = header?.firstMatch(of: /(\d+)\s*([wdhm]?)/), let count = Double(match.1), count > 0 else {
        return updateAfter
      }
      switch match.2 {
      case "w": return count * 7
      case "h": return max(count, 4) / 24
      case "m": return max(count, 240) / 1440
      default: return count
      }
    }
  }

  // An entry of uBlock Origin's assets.json, whose contentURL is one URL or several.
  private struct Asset: Decodable {
    let contentURL: [String]
    let cdnURLs: [String]
    let updateAfter: Double?

    enum CodingKeys: String, CodingKey { case contentURL, cdnURLs, updateAfter }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let urls = try? container.decode([String].self, forKey: .contentURL)
      contentURL = try urls ?? [container.decode(String.self, forKey: .contentURL)]
      cdnURLs = try container.decodeIfPresent([String].self, forKey: .cdnURLs) ?? []
      updateAfter = try container.decodeIfPresent(Double.self, forKey: .updateAfter)
    }
  }

  private(set) var lists: [List]

  var texts: [String] { lists.map(\.text) }

  // `root` is the bundled uBlock Origin, whose contentURL paths are relative to it.
  init(root: URL) throws {
    let assets = try JSONDecoder().decode(
      [String: Asset].self, from: Data(contentsOf: root.appending(path: "assets/assets.json")))
    lists = try Self.keys.compactMap { key -> List? in
      guard let asset = assets[key] else { return nil }
      let remote = (asset.cdnURLs.isEmpty ? asset.contentURL : asset.cdnURLs).compactMap(URL.init(string:))
        .filter { $0.scheme == "https" || $0.scheme == "http" }
      let saved = Self.directory.appending(path: "\(key).txt")
      if let text = try? String(contentsOf: saved, encoding: .utf8) {
        let fetched = try saved.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return List(key: key, text: text, urls: remote, updateAfter: asset.updateAfter ?? 7, fetched: fetched)
      }
      let bundled = asset.contentURL.filter { !$0.hasPrefix("http") }.map { root.appending(path: $0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
      guard let bundled else { return nil }
      return List(
        key: key, text: try String(contentsOf: bundled, encoding: .utf8), urls: remote,
        updateAfter: asset.updateAfter ?? 7)
    }
  }

  // The lists with each due one fetched again and saved; a list whose fetch fails keeps its copy until a later check.
  func fetchingDue() async -> FilterLists {
    var result = self
    for index in lists.indices where lists[index].isDue {
      guard let text = await Self.fetch(lists[index].urls) else { continue }
      do {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try text.write(to: Self.directory.appending(path: "\(lists[index].key).txt"), atomically: true, encoding: .utf8)
      } catch {
        Logger().error("Filter list not saved: \(error)")
      }
      result.lists[index].text = text
      result.lists[index].fetched = .now
    }
    return result
  }

  // The list's text from the first of its URLs that answers with one.
  private static func fetch(_ urls: [URL]) async -> String? {
    for url in urls {
      if let (data, response) = try? await session.data(from: url),
        (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8),
        text.contains("\n"), !text.hasPrefix("<")
      {
        return text
      }
    }
    return nil
  }
}

// The domains a filter applies on: every one, only some, or all but some. A list mixing the two ways cannot be
// expressed and gives nil, as does a negated domain WebKit cannot match (a regex or a wildcard TLD); a positive one
// is left out.
private enum DomainScope: Equatable {
  case all, only([String]), except([String])

  init?(_ list: Substring, separator: Character) {
    var only: [String] = []
    var except: [String] = []
    var leftOut = false
    for entry in list.split(separator: separator) {
      let negated = entry.hasPrefix("~")
      let domain = (negated ? entry.dropFirst() : entry).lowercased()
      if FilterSet.isDomain(domain) {
        negated ? except.append(domain) : only.append(domain)
      } else if negated {
        return nil
      } else {
        leftOut = true
      }
    }
    switch (only.isEmpty, except.isEmpty) {
    case (true, true) where !leftOut: self = .all
    case (false, true): self = .only(only)
    case (true, false) where !leftOut: self = .except(except)
    default: return nil
    }
  }
}

// The filters of a set of lists, sorted into the parts WebKit's chunks are built from.
private struct FilterSet {
  // The rules of one chunk, under WebKit's limit of 150,000: smaller lists compile with half the memory at the peak,
  // and the first one is ready sooner.
  static let maxRules = 50_000
  // A host-anchored pattern's start: any scheme, then the host or a subdomain of it.
  static let hostAnchor = "^[^:]+://+([^:/]+\\.)?"
  // uBlock Origin's separator: any character but a letter, a digit or one of _ - . %.
  static let separator = "[^a-zA-Z0-9_.%-]"
  // The resource types of a filter that names none: everything but the page itself, and child frames.
  static let subresources = [
    "image", "style-sheet", "script", "font", "svg-document", "media", "ping", "fetch", "websocket", "other",
  ]
  static let resourceTypes: [Substring: String] = [
    "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet", "xmlhttprequest": "fetch",
    "xhr": "fetch", "font": "font", "media": "media", "websocket": "websocket", "ping": "ping", "other": "other",
  ]
  // Whether each party option names third-party requests.
  static let parties: [Substring: Bool] = ["third-party": true, "3p": true, "first-party": false, "1p": false]
  static let cosmeticMarkers = ["#@?#", "#@$#", "#@%#", "#?#", "#$#", "#%#", "#@#", "##"]
  // uBlock Origin's procedural operators, which no stylesheet can express.
  static let proceduralOperators = [
    ":has-text(", ":upward(", ":xpath(", ":matches-css", ":style(", ":remove(", ":remove-attr(", ":remove-class(",
    ":watch-attr(", ":min-text-length(", ":others(", ":-abp-", ":matches-path(", ":matches-attr(", ":matches-prop",
    ":matches-media(", ":if(", ":if-not(", ":shadow(", ":contains(", ":nth-ancestor(", ":spath(",
  ]

  // Network blocks, the exceptions to them, and the important blocks no exception lifts, in their chunks' order.
  private var blocks = RuleList()
  private var exceptions = RuleList()
  private var important = RuleList()
  // Hosts whose pages are excepted from every filter.
  private var exceptedPages: [String] = []
  // Element hiding filters, the domains each selector is unhidden on, and the selectors unhidden everywhere.
  private var hides: [(selector: String, scope: DomainScope)] = []
  private var unhidden: [String: Set<String>] = [:]
  private var unhiddenEverywhere: Set<String> = []
  // Hosts excepted from generic hiding, and from all hiding.
  private var genericHidingOff: [String] = []
  private var hidingOff: [String] = []

  // Rules in order without repeats.
  private struct RuleList {
    private(set) var rules: [ContentRule] = []
    private var seen: Set<ContentRule> = []

    mutating func append(_ rule: ContentRule) {
      if seen.insert(rule).inserted {
        rules.append(rule)
      }
    }
  }

  // A network filter's options in the subset WebKit can express.
  private struct Options {
    enum Hiding { case generic, all }

    var scope = DomainScope.all
    var loadType: String?
    var isCaseSensitive = false
    var isImportant = false
    var types: [String] = []
    var top = false
    var child = false
    var all = false
    var hiding: Hiding?

    // Whether anything beyond the domains limits which requests the filter matches.
    var limitsRequests: Bool {
      loadType != nil || isCaseSensitive || isImportant || !types.isEmpty || child || all
    }

    // Adds one option; false for an option outside the subset, which skips the filter.
    mutating func add(_ option: Substring) -> Bool {
      let negated = option.hasPrefix("~")
      let name = negated ? option.dropFirst() : option
      if let thirdParty = FilterSet.parties[name] {
        let value = thirdParty != negated ? "third-party" : "first-party"
        guard loadType == nil || loadType == value else { return false }
        loadType = value
        return true
      }
      guard !negated else { return false }
      if name.hasPrefix("domain=") || name.hasPrefix("from=") {
        guard let scope = DomainScope(name.drop { $0 != "=" }.dropFirst(), separator: "|") else { return false }
        self.scope = scope
        return true
      }
      switch name {
      case "match-case": isCaseSensitive = true
      case "important": isImportant = true
      case "document", "doc": top = true
      case "subdocument", "frame": child = true
      case "all": all = true
      case "elemhide", "ehide": hiding = .all
      case "generichide", "ghide": hiding = .generic
      default:
        guard let type = FilterSet.resourceTypes[name] else { return false }
        if !types.contains(type) {
          types.append(type)
        }
      }
      return true
    }
  }

  // The list's filter lines, trimmed, without blanks and comments, and with uBlock Origin's !#if directives applied as
  // they are for Safari.
  static func activeLines(_ list: String) -> [String] {
    // For each open !#if, whether its lines are left out, or nil when uBlock Origin cannot tell and keeps them.
    var conditions: [Bool?] = []
    var lines: [String] = []
    for raw in list.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      switch line.hasPrefix("!#") ? line.dropFirst(2).prefix(while: \.isLetter) : "" {
      case "if": conditions.append(evaluate(line.dropFirst(4)).map { !$0 })
      case "else":
        if let last = conditions.popLast() {
          conditions.append(last.map { !$0 })
        }
      case "endif": _ = conditions.popLast()
      default:
        if !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), !conditions.contains(true),
          !line.hasPrefix("#") || cosmeticMarker(line)?.range.lowerBound == line.startIndex
        {
          lines.append(line)
        }
      }
    }
    return lines
  }

  // An !#if condition as uBlock Origin evaluates it for Safari: tokens joined left to right by && and ||, true for
  // env_safari and ext_ublock and false for the other tokens it knows, and nil when it holds an unknown token.
  private static func evaluate(_ condition: Substring) -> Bool? {
    var condition = condition.trimmingCharacters(in: .whitespaces)[...]
    if condition.hasPrefix("("), condition.hasSuffix(")") {
      condition = condition.dropFirst().dropLast()
    }
    let words = condition.split(whereSeparator: \.isWhitespace)
    guard words.count % 2 == 1, var result = words.first.flatMap(evaluateToken) else { return nil }
    for index in stride(from: 1, to: words.count, by: 2) {
      guard let value = evaluateToken(words[index + 1]) else { return nil }
      switch words[index] {
      case "||": result = result || value
      case "&&": result = result && value
      default: return nil
      }
    }
    return result
  }

  private static func evaluateToken(_ token: Substring) -> Bool? {
    let negated = token.hasPrefix("!")
    let name = negated ? token.dropFirst() : token
    guard name == "false" || ["env_", "ext_", "cap_", "adguard"].contains(where: { name.hasPrefix($0) }) else {
      return nil
    }
    return (name == "env_safari" || name == "ext_ublock") != negated
  }

  // The cosmetic marker at the line's first #, and where it is.
  static func cosmeticMarker(_ line: String) -> (marker: String, range: Range<String.Index>)? {
    guard let hash = line.firstIndex(of: "#") else { return nil }
    return cosmeticMarkers.first { line[hash...].hasPrefix($0) }.map {
      ($0, hash..<line.index(hash, offsetBy: $0.count))
    }
  }

  // The filter a $badfilter line cancels: the same line without that option.
  static func badfilterTarget(_ line: String) -> String? {
    guard cosmeticMarker(line) == nil else { return nil }
    let exception = line.hasPrefix("@@")
    let (pattern, options) = split(exception ? line.dropFirst(2) : line[...])
    guard options.contains("badfilter") else { return nil }
    let kept = options.filter { $0 != "badfilter" }
    return (exception ? "@@" : "") + pattern + (kept.isEmpty ? "" : "$" + kept.joined(separator: ","))
  }

  // A network filter's pattern and options, split at the $ that starts the options.
  private static func split(_ filter: Substring) -> (pattern: Substring, options: [Substring]) {
    let dollar =
      filter.hasPrefix("/")
      ? filter.ranges(of: "/$").last.map { filter.index(after: $0.lowerBound) } : filter.lastIndex(of: "$")
    guard let dollar else { return (filter, []) }
    return (filter[..<dollar], filter[filter.index(after: dollar)...].split(separator: ","))
  }

  mutating func add(_ line: String) {
    if let (marker, range) = Self.cosmeticMarker(line) {
      guard marker == "##" || marker == "#@#" else { return }
      addHiding(line[range.upperBound...], on: line[..<range.lowerBound], exception: marker == "#@#")
    } else if !line.contains("$$"), !line.contains("$@$") {
      addNetwork(line)
    }
  }

  private mutating func addHiding(_ selector: Substring, on domains: Substring, exception: Bool) {
    guard !selector.isEmpty, !selector.hasPrefix("+js("), !selector.hasPrefix("^"),
      !Self.proceduralOperators.contains(where: { selector.contains($0) }),
      let scope = DomainScope(domains, separator: ",")
    else { return }
    let selector = String(selector)
    guard exception else { return hides.append((selector, scope)) }
    switch scope {
    case .all: unhiddenEverywhere.insert(selector)
    case let .only(domains): unhidden[selector, default: []].formUnion(domains)
    case .except: break
    }
  }

  private mutating func addNetwork(_ line: String) {
    let exception = line.hasPrefix("@@")
    var (pattern, options) = Self.split(exception ? line.dropFirst(2) : line[...])
    if !exception, options.isEmpty {
      if let host = Self.hostsEntry(pattern) {
        pattern = Substring("||\(host)^")
      } else if Self.isHostname(pattern.lowercased()) {
        pattern = Substring("||\(pattern.lowercased())")
      }
    }
    var parsed = Options()
    guard options.allSatisfy({ parsed.add($0) }) else { return }
    if let hiding = parsed.hiding {
      guard exception, !parsed.limitsRequests, !parsed.top, let pages = Self.pages(pattern, parsed.scope) else {
        return
      }
      if hiding == .all {
        hidingOff.append(contentsOf: pages)
      } else {
        genericHidingOff.append(contentsOf: pages)
      }
      return
    }
    if exception, parsed.top {
      guard !parsed.limitsRequests, let pages = Self.pages(pattern, parsed.scope) else { return }
      exceptedPages.append(contentsOf: pages)
      hidingOff.append(contentsOf: pages)
      return
    }
    guard !(exception && parsed.isImportant), let (filters, isHost) = Self.urlFilters(pattern) else { return }
    var trigger = ContentRule.Trigger(isCaseSensitive: parsed.isCaseSensitive ? true : nil)
    switch parsed.scope {
    case .all: break
    case let .only(domains): trigger.ifDomain = domains.map { "*" + $0 }
    case let .except(domains): trigger.unlessDomain = domains.map { "*" + $0 }
    }
    trigger.loadType = parsed.loadType.map { [$0] }
    let triggers = filters.map { filter in
      var filtered = trigger
      filtered.urlFilter = filter
      return filtered
    }
    for trigger in triggers.flatMap({ Self.typed($0, parsed, wholeHost: isHost || exception) }) {
      let rule = ContentRule(trigger: trigger, action: .init(type: exception ? "ignore-previous-rules" : "block"))
      if exception {
        exceptions.append(rule)
      } else if parsed.isImportant {
        important.append(rule)
      } else {
        blocks.append(rule)
      }
    }
  }

  // The trigger once for each load context its resource types need. A filter naming no type matches every
  // subresource and child frame, and also the page itself when it names a whole host, as uBlock Origin's strict
  // blocking does.
  private static func typed(
    _ trigger: ContentRule.Trigger, _ options: Options, wholeHost: Bool
  ) -> [ContentRule.Trigger] {
    guard !options.all else { return [trigger] }
    var types = options.types
    var (top, child) = (options.top, options.child)
    if types.isEmpty, !top, !child {
      guard !wholeHost else { return [trigger] }
      (types, child) = (subresources, true)
    }
    if top, child {
      types.append("document")
      (top, child) = (false, false)
    }
    var triggers: [ContentRule.Trigger] = []
    if !types.isEmpty {
      var typed = trigger
      typed.resourceType = types
      triggers.append(typed)
    }
    if top || child {
      var frame = trigger
      frame.resourceType = ["document"]
      frame.loadContext = [top ? "top-frame" : "child-frame"]
      triggers.append(frame)
    }
    return triggers
  }

  // The host of a hosts-file line, as uBlock Origin reads one: an address, then a host that is not the machine's own.
  private static func hostsEntry(_ line: Substring) -> String? {
    let words = line.split(whereSeparator: \.isWhitespace)
    guard words.count >= 2, words.count == 2 || words[2].hasPrefix("#") else { return nil }
    let host = words[1].lowercased()
    guard isHostname(host), !host.hasPrefix("ip6-"),
      !["0.0.0.0", "broadcasthost", "local", "localhost", "localhost.localdomain"].contains(host)
    else { return nil }
    return host
  }

  // The pages a whole-page exception names: its pattern's host, or the domains of a pattern matching everything.
  private static func pages(_ pattern: Substring, _ scope: DomainScope) -> [String]? {
    let host = pattern.hasPrefix("||") ? pattern.dropFirst(2) : pattern
    let name = (host.hasSuffix("^") ? host.dropLast() : host).lowercased()
    switch scope {
    case .all where isDomain(name): return [name]
    case let .only(domains) where pattern.isEmpty || pattern == "*": return domains
    default: return nil
    }
  }

  // A pattern as WebKit url-filters, and whether it names a whole host; nil for a regex WebKit cannot run or a pattern
  // that is not ASCII. A final separator, which can also be the URL's end, gives two filters, one for each: as one
  // filter with an optional group, a list of urlhaus's paths compiles twenty times slower.
  static func urlFilters(_ pattern: Substring) -> (filters: [String], isHost: Bool)? {
    guard pattern.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
    if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
      let regex = pattern.dropFirst().dropLast()
      return isWebKitRegex(regex) ? ([String(regex)], false) : nil
    }
    var source = pattern
    var filter = ""
    let hostAnchored = source.hasPrefix("||")
    if hostAnchored {
      filter = hostAnchor
      source = source.dropFirst(2)
    } else if source.hasPrefix("|") {
      filter = "^"
      source = source.dropFirst()
    }
    let endAnchored = source.hasSuffix("|")
    if endAnchored {
      source = source.dropLast()
    }
    if filter.isEmpty {
      source = source.drop { $0 == "*" }
    }
    while !endAnchored, source.hasSuffix("*") {
      source = source.dropLast()
    }
    let host = source.hasSuffix("^") ? source.dropLast() : source
    let isHost = hostAnchored && !host.isEmpty && host.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    // After a whole host the path always follows, so its separator cannot be the end.
    let endsInSeparator = source.hasSuffix("^") && !endAnchored && !isHost && source.count > 1
    if endsInSeparator {
      source = source.dropLast()
    }
    for index in source.indices {
      switch source[index] {
      case "*": filter += ".*"
      case "^": filter += separator
      case let character where "\\.+?$()[]{}|".contains(character): filter += "\\\(character)"
      case let character: filter.append(character)
      }
    }
    if endAnchored {
      filter += "$"
    }
    guard !endsInSeparator else { return ([filter + separator, filter + "$"], isHost) }
    return ([filter.isEmpty ? ".*" : filter], isHost)
  }

  // Whether WebKit's regex subset covers the regex: ASCII, no alternation, counted repetition, lookaround,
  // non-capturing group, lazy quantifier, class escape or back reference, and anchors only at its ends.
  private static func isWebKitRegex(_ regex: Substring) -> Bool {
    var inClass = false
    var escaped = false
    var quantified = false
    for index in regex.indices {
      let character = regex[index]
      guard character.isASCII else { return false }
      if escaped {
        guard !character.isLetter, !character.isNumber else { return false }
        (escaped, quantified) = (false, false)
        continue
      }
      switch character {
      case "\\": escaped = true
      case "[": inClass = true
      case "]": inClass = false
      case _ where inClass: break
      case "|", "{", "}": return false
      case "(" where regex[index...].hasPrefix("(?"): return false
      case "^" where index != regex.startIndex: return false
      case "$" where regex.index(after: index) != regex.endIndex: return false
      case _ where quantified && "*+?".contains(character): return false
      default: break
      }
      quantified = !inClass && "*+?".contains(character)
    }
    return !escaped && !inClass
  }

  // A hostname as uBlock Origin's pattern parser recognizes one: dot-separated labels of letters, digits, _ and -,
  // each starting with a letter or digit.
  static func isHostname(_ name: String) -> Bool {
    !name.isEmpty
      && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
        label.first.map { $0.isASCII && ($0.isLowercase || $0.isNumber) } == true
          && label.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-") }
      }
  }

  // A domain WebKit can match: lowercase ASCII letters, digits, dots, hyphens and underscores.
  static func isDomain(_ name: String) -> Bool {
    !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "._-".contains($0)) }
  }

  // One rule lifting every earlier rule of its chunk on the pages of these hosts.
  private static func pageException(_ hosts: [String]) -> [ContentRule] {
    let hosts = Array(Set(hosts)).sorted()
    guard !hosts.isEmpty else { return [] }
    return [ContentRule(trigger: .init(ifDomain: hosts.map { "*" + $0 }), action: .init(type: "ignore-previous-rules"))]
  }

  // Splits rules into slices that leave room for the rules every chunk adds to its slice.
  private static func slices(_ rules: [ContentRule], leaving reserved: Int) -> [ArraySlice<ContentRule>] {
    let size = maxRules - reserved
    return stride(from: 0, to: rules.count, by: size).map { rules[$0..<min($0 + size, rules.count)] }
  }

  // Each chunk holds a share of the blocks, then every exception, then every important block.
  var networkChunks: [[ContentRule]] {
    let tail = exceptions.rules + Self.pageException(exceptedPages) + important.rules
    return Self.slices(blocks.rules, leaving: tail.count).map { Array($0) + tail }
  }

  // Each chunk holds a share of the hiding rules: its generic ones, the exceptions from generic hiding, its specific
  // ones, then the exceptions from all hiding.
  var cosmeticChunks: [[ContentRule]] {
    var rules = RuleList()
    for (selector, scope) in hides where !unhiddenEverywhere.contains(selector) {
      let unhidden = self.unhidden[selector, default: []]
      var trigger = ContentRule.Trigger()
      switch scope {
      case .all:
        trigger.unlessDomain = unhidden.isEmpty ? nil : unhidden.sorted().map { "*" + $0 }
      case let .except(domains):
        trigger.unlessDomain = (domains + unhidden.sorted()).map { "*" + $0 }
      case let .only(domains):
        let kept = domains.filter { !unhidden.contains($0) }
        guard !kept.isEmpty else { continue }
        trigger.ifDomain = kept.map { "*" + $0 }
      }
      rules.append(ContentRule(trigger: trigger, action: .init(type: "css-display-none", selector: selector)))
    }
    let genericOff = Self.pageException(genericHidingOff)
    let allOff = Self.pageException(hidingOff)
    return Self.slices(rules.rules, leaving: genericOff.count + allOff.count).map { slice in
      slice.filter { $0.trigger.ifDomain == nil } + genericOff + slice.filter { $0.trigger.ifDomain != nil } + allOff
    }
  }
}
