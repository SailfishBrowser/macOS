import ComposableArchitecture
import AppKit

extension SharedKey where Self == FileStorageKey<Set<String>>.Default {
  // The pages whose suggestions were removed from the bar. History itself keeps them: the engine has no
  // way to delete a visit.
  static var removedSuggestions: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "RemovedSuggestions.json")), default: []]
  }
}

@Reducer
struct CommandBarFeature {
  enum Suggestion: Equatable {
    case tab(Tab)
    case match(AutocompleteMatch)
    case command(Command)
    // The calculator row: the expression typed and its result.
    case calculation(String, String)

    // A page from history, which the hover X and ⌘⌥Delete remove.
    var isRemovable: Bool {
      if case let .match(match) = self { match.type == .history } else { false }
    }

    // What makes a row the same row across refreshes: a tab stays itself while its title or favicon changes.
    var key: String {
      switch self {
      case let .tab(tab): "tab:\(tab.id)"
      case let .match(match): "match:\(match.url.absoluteString)"
      case let .command(command): "command:\(command.title)"
      case let .calculation(expression, _): "calculation:\(expression)"
      }
    }
  }

  // An app command, listed among the results and run as its menu item would be.
  struct Command: Equatable, Sendable {
    var title: String
    var symbol: String
    var shortcut = ""
    // The menu item's action and tag.
    var action: String
    var tag = 0
    // What the action takes besides: an extension's identifier for Run Extension.
    var argument = ""
    // Other words that find it, as "close" finds Archive Tab.
    var keywords = ""
    // Listed after the search for the typed text, never first.
    var isMinor = false

    func matches(_ query: String) -> Bool {
      let words = (title + " " + keywords).lowercased().split { !$0.isLetter && !$0.isNumber }
      return query.split(separator: " ").allSatisfy { part in words.contains { $0.hasPrefix(part) } }
    }
  }

  @ObservableState
  struct State: Equatable {
    var tabs: [Tab]
    var profile: UUID
    // The space of each tab that is not in the window's selected space.
    var spaceNames: [Tab.ID: String] = [:]
    var isIncognito = false
    var editing: Tab.ID?
    var query = ""
    var matches: [AutocompleteMatch] = []
    // The query `matches` are for; Enter waits for the current one's.
    var matchesQuery = ""
    // Counts the queries started, so that only the newest one's matches are taken. Effects run on the cooperative
    // pool after a hop off the main actor, so under load an older keystroke's effect can run after the newest
    // one's and deliver its matches later.
    var queryID = 0
    var pendingSubmit: Int?
    var selection = 0
    // The site search Tab entered, which the query searches.
    var keyword: Keyword?
    // Actions mode, which Tab enters from an empty field: the commands alone.
    var isActions = false
    var commands: [Command] = []
    // History's favicons for the matches' pages.
    var favicons: [URL: NSImage] = [:]
    // The rows shown before the query changed, which fill out the list until Chrome is done with the new one,
    // so the panel keeps its height while typing.
    var staleRows: [Suggestion] = []
    // Deleting hides the inline completion, as in Chrome.
    var isDeleting = false
    // The rows shown, computed by refreshSuggestions() when what they come from changes: scanning every tab
    // on each read cost tens of scans per keystroke.
    var suggestions: [Suggestion] = []
    // Little Sailfish lists its tabs as recent pages, without "Switch to Tab".
    var showsTabsAsRecents = false
    @Shared(.removedSuggestions) var removed

    init(
      tabs: [Tab], profile: UUID, spaceNames: [Tab.ID: String] = [:], isIncognito: Bool = false, editing: Tab.ID? = nil,
      query: String = "", matches: [AutocompleteMatch] = [], matchesQuery: String = "", showsTabsAsRecents: Bool = false
    ) {
      self.tabs = tabs
      self.profile = profile
      self.spaceNames = spaceNames
      self.isIncognito = isIncognito
      self.editing = editing
      self.query = query
      self.matches = matches
      self.matchesQuery = matchesQuery
      self.showsTabsAsRecents = showsTabsAsRecents
      refreshSuggestions()
    }

    // What autocomplete is asked: ⌘L on an unchanged URL lists the site's recent history, so it asks for the host.
    var effectiveQuery: String {
      editedTab?.url.domain ?? query
    }

    // Removed pages are kept per profile.
    func removedKey(_ url: URL) -> String { "\(profile.uuidString) \(url.absoluteString)" }

    func keeping(_ matches: [AutocompleteMatch]) -> [AutocompleteMatch] {
      matches.filter { $0.type != .history || !removed.contains(removedKey($0.url)) }
    }

    // The default match's rest of the text, shown selected after the query. It stays while typing into it
    // until the new matches arrive, so it never flickers.
    var inline: String {
      guard !isDeleting, selection == 0, let first = matches.first, !first.inlineAutocompletion.isEmpty else { return "" }
      let full = matchesQuery + first.inlineAutocompletion
      guard full.count > query.count, full.lowercased().hasPrefix(query.lowercased()) else { return "" }
      return String(full.dropFirst(query.count))
    }

    // The site search Tab would enter: the default match's.
    var keywordHint: Keyword? {
      guard keyword == nil, matchesQuery == query, let first = matches.first,
        let keyword = first.keyword, let name = first.keywordName
      else { return nil }
      return Keyword(keyword: keyword, name: name)
    }

    var offersActions: Bool {
      keyword == nil && !isActions && query.isEmpty && !commands.isEmpty
    }

    // The pages the suggestions open, which show favicons.
    var pages: [URL] {
      suggestions.compactMap {
        switch $0 {
        case let .tab(tab): tab.favicon == nil ? tab.url : nil
        case let .match(match): match.type == .search ? nil : match.url
        case .command, .calculation: nil
        }
      }
    }

    // The tab being edited while its URL is unchanged.
    var editedTab: Tab? {
      tabs.first { $0.id == editing && $0.url.absoluteString == query }
    }

    mutating func refreshSuggestions() {
      let rows = rows
      guard !isActions else {
        suggestions = rows
        return
      }
      let stale = staleRows.filter { row in !rows.contains { $0.key == row.key } }
      suggestions = Array((rows + stale).prefix(max(rows.count, staleRows.count)))
    }

    private var rows: [Suggestion] {
      // Chrome can return one search twice, as typed and as suggested; it is listed once.
      var searches = Set<String>()
      let matches = matches.filter { $0.type != .search || searches.insert($0.contents.lowercased()).inserted }
      // ⌘L lists the current page, the site's recent history, then recent tabs.
      if let editedTab {
        let history = matches.filter { $0.type != .search && $0.url != editedTab.url && $0.url.domain == editedTab.url.domain }
        let recent = tabs.filter { $0.id != editing }.map(Suggestion.tab)
        return Array(([.tab(editedTab)] + history.map(Suggestion.match) + recent).prefix(5))
      }
      let query = query.trimmingCharacters(in: .whitespaces).lowercased()
      let commands = commands.filter { $0.matches(query) }
      if isActions { return Array(commands.prefix(5).map(Suggestion.command)) }
      let others = tabs.filter { $0.id != editing }
      // The empty ⌘T: the space's open tabs alone.
      guard !query.isEmpty else { return others.prefix(showsTabsAsRecents ? 5 : 4).map(Suggestion.tab) }
      if keyword == nil, let result = Calculator.evaluate(self.query) {
        return [.calculation(self.query.trimmingCharacters(in: .whitespaces), result)]
      }
      // The best match (as its open tab if there is one), the search for the typed text, matching
      // commands and open tabs, then sites before search suggestions. A page matches a tab regardless of "www.".
      // A command comes first unless the best match is a site the text completes to.
      let bestTab = matches.first.flatMap { best in others.first { $0.url.page == best.url.page } }
      let tabs = others.filter { $0.matches(query) && $0 != bestTab }
      let rest = matches.dropFirst().filter { match in !tabs.contains { $0.url.page == match.url.page } }
      let verbatim = rest.first { $0.type == .search && $0.contents.lowercased() == query }
      let best = bestTab.map(Suggestion.tab) ?? matches.first.map(Suggestion.match)
      let completes = bestTab != nil || matches.first.map { $0.type != .search && !$0.inlineAutocompletion.isEmpty } == true
      let lead = completes ? nil : commands.first { !$0.isMinor }
      let rows: [Suggestion] =
        [lead.map(Suggestion.command), best, verbatim.map(Suggestion.match)].compactMap { $0 }
        + commands.filter { $0 != lead }.map(Suggestion.command)
        + tabs.prefix(2).map(Suggestion.tab)
        + rest.filter { $0.type != .search }.map(Suggestion.match)
        + rest.filter { $0.type == .search && $0 != verbatim }.map(Suggestion.match)
      return Array(rows.prefix(5))
    }
  }

  struct Keyword: Equatable {
    var keyword: String
    var name: String
  }

  enum Action {
    case appeared
    case enterKeyword
    case faviconLoaded(URL, NSImage)
    case leaveKeyword
    case delegate(Delegate)
    case matchesFinished(Int)
    case matchesUpdated(Int, String, [AutocompleteMatch])
    case moveSelection(Int)
    case queryChanged(String)
    // The row's hover X or ⌘⌥Delete: the page leaves the suggestions.
    case removeSuggestion(Int)
    case submit(Int)
    // ⌘Enter: the row's page opens in a Little Sailfish.
    case submitInLittleSailfish(Int)

    @CasePathable
    enum Delegate {
      case open(URL)
      case openInLittleSailfish(URL)
      case selectTab(Tab.ID)
      case run(Command)
    }
  }

  @Dependency(\.autocomplete) var autocomplete
  @Dependency(\.dismiss) var dismiss

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appeared:
        return .merge(query(&state), loadFavicons(state))

      case .delegate:
        return .none

      case let .faviconLoaded(url, favicon):
        // Matches may have moved on since it was asked for.
        guard state.pages.contains(url) else { return .none }
        state.favicons[url] = favicon
        return .none

      case .enterKeyword:
        if state.offersActions {
          state.isActions = true
          state.selection = 0
          state.refreshSuggestions()
          return .none
        }
        guard let keyword = state.keywordHint else { return .none }
        state.keyword = keyword
        return clear(&state)

      case .leaveKeyword:
        state.keyword = nil
        state.isActions = false
        return clear(&state)

      case let .matchesFinished(id):
        guard id == state.queryID else { return .none }
        state.staleRows = []
        state.refreshSuggestions()
        return .none

      case let .matchesUpdated(id, query, matches):
        guard id == state.queryID else { return .none }
        state.matches = state.keeping(matches)
        state.matchesQuery = query
        state.refreshSuggestions()
        state.selection = min(state.selection, max(state.suggestions.count - 1, 0))
        let favicons = loadFavicons(state)
        guard let index = state.pendingSubmit else { return favicons }
        state.pendingSubmit = nil
        return .merge(favicons, .send(.submit(index)))

      case let .moveSelection(offset):
        state.selection = min(max(state.selection + offset, 0), max(state.suggestions.count - 1, 0))
        return .none

      case let .queryChanged(query):
        state.isDeleting = state.query.hasPrefix(query)
        state.selection = 0
        guard query != state.query else { return .none }
        state.staleRows = state.suggestions
        state.query = query
        state.refreshSuggestions()
        return self.query(&state)

      case let .removeSuggestion(index):
        guard state.suggestions.indices.contains(index), state.suggestions[index].isRemovable,
          case let .match(match) = state.suggestions[index]
        else { return .none }
        let key = state.removedKey(match.url)
        state.$removed.withLock { _ = $0.insert(key) }
        state.matches = state.keeping(state.matches)
        state.staleRows = []
        state.refreshSuggestions()
        state.selection = min(state.selection, max(state.suggestions.count - 1, 0))
        return .none

      case let .submit(index):
        guard state.isActions || state.matchesQuery == state.effectiveQuery else {
          state.pendingSubmit = index
          return .none
        }
        guard state.suggestions.indices.contains(index) else { return .none }
        switch state.suggestions[index] {
        case let .tab(tab):
          return .send(.delegate(.selectTab(tab.id)))
        case let .command(command):
          return .send(.delegate(.run(command)))
        case let .match(match):
          return .run { [profile = state.profile, incognito = state.isIncognito] send in
            await autocomplete.select(profile, incognito, match.url)
            await send(.delegate(.open(match.url)))
          }
        case let .calculation(_, result):
          // Enter copies the answer.
          return .run { _ in
            await MainActor.run {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(result, forType: .string)
            }
            await dismiss()
          }
        }

      case let .submitInLittleSailfish(index):
        guard state.suggestions.indices.contains(index) else { return .none }
        switch state.suggestions[index] {
        case let .tab(tab):
          return .send(.delegate(.openInLittleSailfish(tab.url)))
        case let .match(match):
          return .run { [profile = state.profile, incognito = state.isIncognito] send in
            await autocomplete.select(profile, incognito, match.url)
            await send(.delegate(.openInLittleSailfish(match.url)))
          }
        case .command, .calculation:
          return .send(.submit(index))
        }
      }
    }
  }

  private func loadFavicons(_ state: State) -> Effect<Action> {
    let urls = state.pages.filter { state.favicons[$0] == nil }
    return .run { [profile = state.profile, incognito = state.isIncognito] send in
      for url in urls {
        if let favicon = await autocomplete.favicon(profile, incognito, url) {
          await send(.faviconLoaded(url, favicon))
        }
      }
    }
  }

  private func clear(_ state: inout State) -> Effect<Action> {
    state.query = ""
    state.matches = []
    state.matchesQuery = ""
    state.selection = 0
    state.refreshSuggestions()
    return query(&state)
  }

  // Older queries are not cancelled with cancelInFlight: it registers inside the effect body, which runs on the
  // cooperative pool after a hop off the main actor, so under load an older keystroke's body can register after,
  // and cancel, the newest query's effect, whose sends are then dropped while the engine drops the older query
  // as superseded, and no matches ever arrive. The engine drops a query requested before one it started and
  // ends the stream of one it supersedes, so an older effect ends on its own.
  private func query(_ state: inout State) -> Effect<Action> {
    guard !state.isActions else { return .none }
    state.queryID += 1
    // sailfish://settings and the like are Chromium's pages.
    let text = state.effectiveQuery
    let typed = text.hasPrefix("sailfish://") ? "chrome://" + String(text.dropFirst("sailfish://".count)) : text
    return .run {
      [
        id = state.queryID, profile = state.profile, incognito = state.isIncognito, keyword = state.keyword?.keyword,
        now = ContinuousClock.now
      ] send in
      for await matches in await autocomplete.query(profile, incognito, typed, keyword, now) {
        await send(.matchesUpdated(id, text, matches))
      }
      await send(.matchesFinished(id))
    }
  }

  static func searchURL(_ query: String) -> URL {
    var components = URLComponents(string: "https://www.google.com/search")!
    components.queryItems = [URLQueryItem(name: "q", value: query)]
    return components.url!
  }
}

extension Tab {
  // Whether a word of the title, or the site, starts with `query` (lowercased).
  func matches(_ query: String) -> Bool {
    let title = title.lowercased()
    return title.hasPrefix(query) || url.domain.hasPrefix(query)
      || title.split { !$0.isLetter && !$0.isNumber }.contains { $0.hasPrefix(query) }
  }
}
