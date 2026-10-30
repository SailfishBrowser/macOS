import ComposableArchitecture
@preconcurrency import EngineCore
import Foundation

@DependencyClient
struct ImportClient: Sendable {
  var sources: @Sendable () -> [BrowserSource] = { [] }
  var bookmarks: @Sendable (_ browser: SourceBrowser, _ profile: BrowserProfile) async throws -> [ArcData.Row]
  // The Chromium profiles of an Arc data folder, for their history.
  var arcProfiles: @Sendable (_ folder: URL) -> [BrowserProfile] = { _ in [] }
  // Returns how many pages the profile's history gained.
  var history: @Sendable (_ browser: SourceBrowser, _ profile: BrowserProfile, _ into: Profile.ID) async throws -> Int
  // Keeps the profiles' favicons of the pages for their tabs.
  var favicons: @Sendable (_ profiles: [BrowserProfile], _ pages: [URL]) async -> Void
  // The key a Chromium browser encrypts its passwords and cookies with, from the keychain, which asks the user first.
  var safeStorageKey: @Sendable (_ browser: SourceBrowser) async throws -> Data
  // These return how many the profile took.
  var passwords: @Sendable (_ browser: SourceBrowser, _ profile: BrowserProfile, _ key: Data, _ into: Profile.ID) async throws -> Int
  // Safari's need no key.
  var cookies: @Sendable (_ browser: SourceBrowser, _ profile: BrowserProfile, _ key: Data?, _ into: Profile.ID) async throws -> Int
  // Zen's: each container's go to the profile of its name, those of none to the first, and others are left out.
  var containerCookies: @Sendable (_ profile: BrowserProfile, _ into: [String: Profile.ID], _ first: Profile.ID) async throws -> Int
  // A passwords CSV file, as Safari and the Passwords app export them.
  var passwordsFile: @Sendable (_ file: URL, _ into: Profile.ID) async throws -> Int
  var isDefaultBrowser: @Sendable () -> Bool = { false }
  var makeDefaultBrowser: @Sendable () async -> Void
}

extension ImportClient: TestDependencyKey {
  // Imports in tests keep no favicons unless they say how.
  static let testValue = {
    var client = Self()
    client.favicons = { _, _ in }
    return client
  }()
}

extension DependencyValues {
  var browserImport: ImportClient {
    get { self[ImportClient.self] }
    set { self[ImportClient.self] = newValue }
  }
}

extension ImportClient: DependencyKey {
  static let liveValue = Self(
    sources: { BrowserSources.detect(home: .homeDirectory) },
    bookmarks: { browser, profile in
      try await Task.detached { try BookmarksReader.read(browser, profile, now: .now) }.value
    },
    arcProfiles: { BrowserSources.chromiumProfiles($0.appending(path: "User Data"), .arc) },
    history: { browser, profile, into in
      let entries = try await Task.detached {
        try HistoryReader.read(browser.historySource(profile)).map {
          ECHistoryEntry(
            urlString: $0.url, title: $0.title, visitCount: $0.visitCount, typedCount: $0.typedCount,
            lastVisit: $0.lastVisit)
        }
      }.value
      return await Engine.shared.importHistory(entries, into: into)
    },
    favicons: { profiles, pages in
      await Task.detached {
        let icons = ImportedFavicons.read(profiles.map { $0.folder.appending(path: "Favicons") }, pages: pages)
        try? ImportedFavicons.save(icons)
      }.value
    },
    safeStorageKey: { browser in
      try await Task.detached { SafeStorage.key(password: try SafeStorage.password(service: browser.safeStorage!)) }.value
    },
    passwords: { browser, profile, key, into in
      let file = profile.folder.appending(path: "Login Data")
      // A profile that never saved one may have none.
      guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
      let passwords = try await Task.detached {
        try LoginsReader.passwords(file, key: key).map {
          ECPassword(urlString: $0.url, username: $0.username, password: $0.password)
        }
      }.value
      return await Engine.shared.importPasswords(passwords, into: into)
    },
    cookies: { browser, profile, key, into in
      let file = browser.cookiesFile(profile)
      // Safari's reader tells a missing file from one macOS keeps from Sailfish.
      guard key == nil || FileManager.default.fileExists(atPath: file.path) else { return 0 }
      let cookies = try await Task.detached {
        try (key.map { try LoginsReader.cookies(file, key: $0, now: .now) } ?? SafariCookiesReader.read(file, now: .now))
          .map { ECCookie($0) }
      }.value
      return await Engine.shared.importCookies(cookies, into: into)
    },
    containerCookies: { profile, profiles, first in
      let containers = try await Task.detached {
        Dictionary(grouping: try ZenReader.cookies(profile.folder, now: .now), by: \.container)
      }.value
      var count = 0
      for (container, cookies) in containers {
        guard let into = container.map({ profiles[$0] }) ?? first else { continue }
        count += await Engine.shared.importCookies(cookies.map { ECCookie($0.cookie) }, into: into)
      }
      return count
    },
    passwordsFile: { file, into in
      let csv: String
      do {
        csv = try String(contentsOf: file, encoding: .utf8)
      } catch {
        throw ImportError.unreadable
      }
      return await Engine.shared.importPasswords(ECPassword.passwords(fromCSV: csv), into: into)
    },
    isDefaultBrowser: { Shell.isDefaultBrowser },
    makeDefaultBrowser: { await Shell.makeDefaultBrowser() }
  )
}

extension ECCookie {
  convenience init(_ cookie: ImportedCookie) {
    self.init(
      name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, creation: cookie.creation,
      expiry: cookie.expiry, lastAccess: cookie.lastAccess, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly,
      sameSite: cookie.sameSite)
  }
}

// The pages, passwords and cookies come made off the main thread; each profile's go to the engine in one call.
extension Engine {
  func importHistory(_ entries: [ECHistoryEntry], into profile: UUID) async -> Int {
    await context(profile).importHistory(entries)
  }

  func importPasswords(_ passwords: [ECPassword], into profile: UUID) async -> Int {
    let context = await context(profile)
    return await withCheckedContinuation { continuation in
      context.import(passwords) { continuation.resume(returning: $0) }
    }
  }

  func importCookies(_ cookies: [ECCookie], into profile: UUID) async -> Int {
    let context = await context(profile)
    return await withCheckedContinuation { continuation in
      context.import(cookies) { continuation.resume(returning: $0) }
    }
  }
}

// Whether the first-run onboarding is still to be gone through: pending from a first launch, with no saved state,
// until its last step. Those who had state before it existed never see it.
enum Onboarding: String, Sendable {
  case undecided, pending, done
}

extension SharedKey where Self == AppStorageKey<Onboarding>.Default {
  static var onboarding: Self { Self[.appStorage("onboarding"), default: .undecided] }
}

// Import from another browser: pick one of those installed, then what to take. Arc's and Zen's spaces come as they
// are; other browsers' bookmarks become pinned tabs and folders of a new space, in the first profile.
@Reducer
struct ImportFeature {
  enum Step: Equatable {
    case browsers, arc, options, importing, finished
    // The onboarding steps after the import, in order.
    case defaultBrowser, theme, adBlocker, mediaFolders, welcome
  }

  struct Options: Equatable, Sendable {
    var browser: SourceBrowser
    var profiles: [BrowserProfile]
    var profile: BrowserProfile
    var spaceName: String
    // nil while they load.
    var bookmarks: [ArcData.Row]?
    var failure: ImportError?
    var includesBookmarks = true
    var includesHistory = true
    // Safari's come from a CSV file its user exports.
    var includesPasswords: Bool
    var passwordsFile: URL?
    var includesCookies = true

    init(browser: SourceBrowser, profiles: [BrowserProfile], profile: BrowserProfile, spaceName: String) {
      self.browser = browser
      self.profiles = profiles
      self.profile = profile
      self.spaceName = spaceName
      includesPasswords = browser != .safari
    }

    var canImport: Bool {
      bookmarks != nil
        && (includesBookmarks
          ? !spaceName.trimmingCharacters(in: .whitespaces).isEmpty
          : includesHistory || includesPasswords || includesCookies)
    }
  }

  // What an import takes besides spaces.
  struct Transfer: Equatable, Sendable {
    var history = false
    var passwords = false
    var cookies = false
    var passwordsFile: URL?
  }

  struct Summary: Equatable {
    var browser: SourceBrowser
    var spaces = 0
    var tabs = 0
    var pages = 0
    // nil when not imported.
    var passwords: Int?
    var cookies: Int?
    var failure: ImportError?
  }

  @ObservableState
  struct State: Equatable {
    var step = Step.browsers
    // The step it opened on, which Back from leaves the import.
    var entry = Step.browsers
    var sources: [BrowserSource] = []
    var arc: ArcImportFeature.State?
    var options: Options?
    var summary: Summary?
    var isOnboarding = false
    // The first space's name the theme step offers to change; nil when an import brought the spaces.
    var spaceName: String?
    @Shared(.onboarding) var onboarding
    @Shared(.mediaFoldersAsked) var mediaFoldersAsked

    // The onboarding opens on the import.
    static func onboarding(spaceName: String) -> Self { Self(isOnboarding: true, spaceName: spaceName) }

    // Opens on the Arc import of the folder.
    static func arc(folder: URL) -> Self {
      Self(step: .arc, entry: .arc, arc: ArcImportFeature.State(folder: folder))
    }
  }

  enum Action: BindableAction {
    case appeared
    case arc(ArcImportFeature.Action)
    case backTapped
    case binding(BindingAction<State>)
    case bookmarksLoaded(Result<[ArcData.Row], ImportError>)
    case browserTapped(SourceBrowser)
    case delegate(Delegate)
    case doneTapped
    case finished(Summary)
    case importTapped
    case makeDefaultTapped
    // Raises the macOS access prompts for the Library's Media folders, then moves on.
    case mediaFoldersTapped
    // Leaves an onboarding step for the next: Maybe Later, Not Now or Continue.
    case nextTapped
    case passwordsFileChosen(URL)
    case profileChosen(BrowserProfile)
    case sourcesLoaded([BrowserSource])
    case themeChanged(SpaceTheme)
    case themeChosen(SpaceTheme)

    @CasePathable
    enum Delegate {
      // The theme onboarding picks for the space the window shows, and its name when changed.
      case theme(SpaceTheme, name: String?)
      // The theme being picked, which the window shows until Continue keeps it or Not Now clears it.
      case previewTheme(SpaceTheme?)
      case merge(ArcData, ArcShortcuts, Set<ArcImportFeature.Category>, from: SourceBrowser)
    }
  }

  @Dependency(\.arcImport) var arcImport
  @Dependency(\.browserImport) var browserImport
  @Dependency(\.dismiss) var dismiss
  @Dependency(\.requestMediaFolders) var requestMediaFolders

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .appeared:
        return .run { send in await send(.sourcesLoaded(browserImport.sources())) }

      case let .arc(.delegate(.import(data, shortcuts, included))):
        let arc = state.arc!
        state.step = .importing
        let bookmarks = included.contains(.bookmarks) && data.bookmarks != nil ? 1 : 0
        let summary = Summary(
          browser: arc.browser, spaces: (included.contains(.spaces) ? data.spaces.count : 0) + bookmarks,
          tabs: Self.tabCount(data, included))
        let transfer = Transfer(
          history: included.contains(.history), passwords: arc.browser == .arc && included.contains(.passwords),
          cookies: included.contains(.cookies), passwordsFile: included.contains(.passwords) ? arc.passwordsFile : nil)
        // A Zen profile is one person's, as Arc's Default is.
        let profiles =
          arc.browser == .arc ? browserImport.arcProfiles(arc.folder) : arc.profiles.filter { $0.folder == arc.folder }
        return .concatenate(
          favicons(profiles, data),
          .send(.delegate(.merge(data, shortcuts, included, from: arc.browser))),
          self.transfer(arc.browser, profiles, transfer, summary, mapped: arc.browser == .arc)
        )

      case .arc(.delegate(.cancel)):
        return back(&state)

      case .arc:
        return .none

      case .backTapped:
        return back(&state)

      case .binding:
        return .none

      case let .bookmarksLoaded(result):
        switch result {
        case let .success(rows): state.options?.bookmarks = rows
        case let .failure(failure): state.options?.failure = failure
        }
        return .none

      case let .browserTapped(browser):
        if browser == .arc {
          state.arc = ArcImportFeature.State(folder: arcImport.defaultFolder())
          state.step = .arc
          return .none
        }
        guard let source = state.sources.first(where: { $0.browser == browser }) else { return .none }
        if browser == .zen {
          state.arc = ArcImportFeature.State(browser: .zen, folder: source.profiles[0].folder, profiles: source.profiles)
          state.step = .arc
          return .none
        }
        state.options = Options(
          browser: browser, profiles: source.profiles, profile: source.profiles[0], spaceName: browser.rawValue)
        state.step = .options
        return load(state.options!)

      case .delegate:
        return .none

      case .doneTapped:
        return state.isOnboarding && state.step != .welcome ? next(&state) : finish(&state)

      case .makeDefaultTapped:
        return .run { send in
          await browserImport.makeDefaultBrowser()
          await send(.nextTapped)
        }

      case .mediaFoldersTapped:
        // A second press while the prompts are up does nothing.
        guard !state.mediaFoldersAsked else { return .none }
        state.$mediaFoldersAsked.withLock { $0 = true }
        return .run { send in
          await requestMediaFolders()
          await send(.nextTapped)
        }

      case .nextTapped:
        return .concatenate(state.step == .theme ? .send(.delegate(.previewTheme(nil))) : .none, next(&state))

      case let .passwordsFileChosen(file):
        state.options?.passwordsFile = file
        state.options?.includesPasswords = true
        return .none

      case let .themeChanged(theme):
        return .send(.delegate(.previewTheme(theme)))

      case let .themeChosen(theme):
        let name = state.spaceName?.trimmingCharacters(in: .whitespaces)
        return .concatenate(.send(.delegate(.theme(theme, name: name?.isEmpty == false ? name : nil))), next(&state))

      case let .finished(summary):
        state.summary = summary
        state.step = .finished
        if summary.spaces > 0 {
          state.spaceName = nil
        }
        return .none

      case .importTapped:
        guard let options = state.options, options.canImport else { return .none }
        state.step = .importing
        var data = ArcData()
        if options.includesBookmarks {
          let name = options.spaceName.trimmingCharacters(in: .whitespaces)
          data.spaces = [ArcData.Space(name: name, icon: "", profile: nil, pinned: options.bookmarks!, today: [])]
        }
        let included: Set<ArcImportFeature.Category> = [.spaces, .pinnedTabs]
        let summary = Summary(browser: options.browser, spaces: data.spaces.count, tabs: Self.tabCount(data, included))
        return .concatenate(
          favicons([options.profile], data),
          data.spaces.isEmpty ? .none : .send(.delegate(.merge(data, ArcShortcuts(), included, from: options.browser))),
          transfer(
            options.browser, [options.profile],
            Transfer(
              history: options.includesHistory, passwords: options.includesPasswords && options.browser != .safari,
              cookies: options.includesCookies, passwordsFile: options.includesPasswords ? options.passwordsFile : nil),
            summary, mapped: false)
        )

      case let .profileChosen(profile):
        state.options?.profile = profile
        state.options?.bookmarks = nil
        state.options?.failure = nil
        return load(state.options!)

      case let .sourcesLoaded(sources):
        state.sources = sources
        return .none
      }
    }
    .ifLet(\.arc, action: \.arc) {
      ArcImportFeature()
    }
  }

  private func back(_ state: inout State) -> Effect<Action> {
    guard state.step != state.entry else { return .run { _ in await dismiss() } }
    state.step = .browsers
    state.arc = nil
    state.options = nil
    return .none
  }

  // The onboarding step after this one; the default browser step is left out when this browser already is. The
  // media folders step is left out once asked, as when an onboarding quit before its end is gone through again.
  private func next(_ state: inout State) -> Effect<Action> {
    let steps: [Step] = [.browsers, .defaultBrowser, .theme, .adBlocker, .mediaFolders, .welcome]
    // The import's own steps count as its first.
    var index = (steps.firstIndex(of: state.step) ?? 0) + 1
    if steps[index] == .defaultBrowser, browserImport.isDefaultBrowser() {
      index += 1
    }
    if steps[index] == .mediaFolders, state.mediaFoldersAsked {
      index += 1
    }
    state.step = steps[index]
    state.arc = nil
    state.options = nil
    return .none
  }

  private func finish(_ state: inout State) -> Effect<Action> {
    if state.isOnboarding {
      state.$onboarding.withLock { $0 = .done }
    }
    return .run { _ in await dismiss() }
  }

  private func load(_ options: Options) -> Effect<Action> {
    .run { send in
      do {
        await send(.bookmarksLoaded(.success(try await browserImport.bookmarks(options.browser, options.profile))))
      } catch {
        await send(.bookmarksLoaded(.failure(error as? ImportError ?? .unreadable)))
      }
    }
  }

  // Before the tabs show, so that they have their favicons at once.
  private func favicons(_ profiles: [BrowserProfile], _ data: ArcData) -> Effect<Action> {
    let pages = Self.pages(data)
    return pages.isEmpty ? .none : .run { _ in await browserImport.favicons(profiles, pages) }
  }

  // Each profile's history, passwords and cookies go to the first profile, or, from Arc, to the profile of its name
  // the merge made; a profile without one is left out, so one person's data never lands in another's. Zen's cookies
  // follow their containers so. A Chromium browser's key is asked for once, for all its profiles.
  private func transfer(
    _ browser: SourceBrowser, _ sources: [BrowserProfile], _ transfer: Transfer, _ summary: Summary, mapped: Bool
  ) -> Effect<Action> {
    .run { send in
      @Shared(.profiles) var profiles
      var summary = summary
      func count(_ work: () async throws -> Int) async -> Int {
        do {
          return try await work()
        } catch {
          summary.failure = error as? ImportError ?? .unreadable
          return 0
        }
      }
      summary.passwords = transfer.passwords || transfer.passwordsFile != nil ? 0 : nil
      summary.cookies = transfer.cookies ? 0 : nil
      var key: Data?
      if browser.safeStorage != nil, transfer.passwords || transfer.cookies, !sources.isEmpty {
        do {
          key = try await browserImport.safeStorageKey(browser)
        } catch {
          summary.failure = error as? ImportError ?? .keychainDenied
        }
      }
      for source in sources {
        let target = source.isDefault || !mapped ? profiles.first?.id : profiles.first { $0.name == source.name }?.id
        guard let target else { continue }
        if transfer.history {
          summary.pages += await count { try await browserImport.history(browser, source, target) }
        }
        if transfer.passwords, let key {
          summary.passwords! += await count { try await browserImport.passwords(browser, source, key, target) }
        }
        if transfer.cookies, browser == .zen {
          let names = Dictionary(profiles.map { ($0.name, $0.id) }) { first, _ in first }
          summary.cookies! += await count { try await browserImport.containerCookies(source, names, target) }
        } else if transfer.cookies, key != nil || browser == .safari {
          summary.cookies! += await count { try await browserImport.cookies(browser, source, key, target) }
        }
      }
      if let file = transfer.passwordsFile, let target = profiles.first?.id {
        summary.passwords = await count { try await browserImport.passwordsFile(file, target) }
      }
      await send(.finished(summary))
    }
  }

  // The pages of the tabs, archived tabs and bookmarks.
  static func pages(_ data: ArcData) -> [URL] {
    func pages(_ rows: [ArcData.Row]) -> [URL] {
      rows.flatMap { row in
        switch row {
        case let .tab(tab): [tab.url]
        case let .folder(_, rows): pages(rows)
        }
      }
    }
    return data.spaces.flatMap { pages($0.pinned) + $0.today.map(\.url) } + data.favorites.flatMap { $0.tabs.map(\.url) }
      + data.archive.map(\.url) + pages(data.bookmarks?.pinned ?? [])
  }

  // The tabs among the rows, however deep.
  static func tabCount(_ rows: [ArcData.Row]) -> Int {
    rows.reduce(0) {
      if case let .folder(_, rows) = $1 { return $0 + tabCount(rows) }
      return $0 + 1
    }
  }

  // The tabs a merge of what was chosen adds, before favorites the profile has already are left out.
  static func tabCount(_ data: ArcData, _ included: Set<ArcImportFeature.Category>) -> Int {
    var tabs = 0
    if included.contains(.spaces) {
      tabs += included.contains(.pinnedTabs) ? data.spaces.map { tabCount($0.pinned) }.reduce(0, +) : 0
      tabs += included.contains(.todayTabs) ? data.spaces.map(\.today.count).reduce(0, +) : 0
    }
    tabs += included.contains(.favorites) ? data.favorites.map(\.tabs.count).reduce(0, +) : 0
    tabs += included.contains(.bookmarks) ? data.bookmarks.map { tabCount($0.pinned) } ?? 0 : 0
    return tabs
  }
}
