import ComposableArchitecture
import Foundation
import OSLog

@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var windows: IdentifiedArrayOf<WindowFeature.State> = []
    var downloads = DownloadsFeature.State()
    var littleSailfishes: IdentifiedArrayOf<LittleSailfishFeature.State> = []
    // Little Sailfish windows closed with a page, last closed last, which ⇧⌘T opens again.
    var closedLittleSailfishes: [ClosedLittleSailfish] = []
    var isLoaded = false
    // URLs to open once the saved windows have loaded; nil after that.
    var pendingURLs: [URL]? = []
    @Shared(.profiles) var profiles
    @Shared(.linkRoutes) var linkRoutes
    @Shared(.archive) var archive
    @Shared(.littleSailfishHintShown) var isLittleSailfishHintShown
    @Shared(.onboarding) var onboarding
    @Shared(.firstLaunch) var firstLaunch
    @Shared(.mediaFoldersAsked) var mediaFoldersAsked
    @Shared(.readyUpdate) var readyUpdate
    // Spaces whose profile was missing on this computer at launch, reverted to Default; shown once, then cleared.
    var recoveredSpaces: [String] = []
    // The window last made key; its space is the globally last focused one, which a relaunch brings to the front.
    var focusedWindowID: WindowFeature.State.ID?
    // The last regular window once it closed: saved with the others, and back with the next window.
    var closedWindow: Snapshot.Window?

    // Toasts that belong to no window show in the last focused one.
    var toastWindowID: WindowFeature.State.ID? {
      focusedWindowID.flatMap { windows[id: $0]?.id } ?? windows.last?.id
    }

    var focusedSpace: Space? {
      (focusedWindowID.flatMap { windows[id: $0] } ?? windows.last { !$0.isIncognito })?.spaces.selected
    }

    // Default (the first profile) and those any window uses, incognito, closed and Little Sailfish included, are kept.
    func canDeleteProfile(_ id: Profile.ID) -> Bool {
      profiles.first?.id != id && profiles[id: id] != nil
        && !windows.contains { $0.spaces.spaces.contains { $0.profileID == id } }
        && closedWindow?.spaces.spaces.contains { $0.profileID == id } != true
        && !littleSailfishes.contains { $0.profileID == id }
    }

    var unusedProfiles: [Profile] {
      profiles.filter { canDeleteProfile($0.id) }
    }

    // The last regular window with a space using the profile.
    func window(using profile: Profile.ID) -> WindowFeature.State? {
      windows.last { !$0.isIncognito && $0.spaces.spaces.contains { $0.profileID == profile } }
    }

    // The spaces a Little Sailfish of the profile can open its page in; the first is the last window's selected one,
    // the most recent space.
    static func littleSailfishSpaces(_ windows: IdentifiedArrayOf<WindowFeature.State>, for profile: Profile.ID) -> [Space] {
      let selected = windows.last { !$0.isIncognito }.map { [$0.spaces.selected] } ?? []
      let all = windows.filter { !$0.isIncognito }.flatMap(\.spaces.spaces)
      return (selected + all.filter { !selected.contains($0) }).filter { $0.profileID == profile }
    }

    func spaceCount(_ profile: Profile.ID) -> Int {
      windows.filter { !$0.isIncognito }.flatMap(\.spaces.spaces).filter { $0.profileID == profile }.count
    }

    // Saved histories are kept for this many archived tabs, the newest.
    static let archivedSessions = 1000

    // The pages whose saved history is kept: those of open tabs, of the newest archived ones (which keep the page
    // under the tab's id) and of those undo can bring back.
    var sessionIDs: Set<UUID> {
      var tabs = windows.flatMap { $0.spaces.spaces.flatMap(\.tabs) }
      tabs += profiles.flatMap(\.favorites)
      tabs += windows.compactMap { $0.peek?.tab }
      tabs += littleSailfishes.compactMap(\.tab)
      for undo in windows.flatMap(\.undoStack) {
        switch undo {
        case let .archive(_, closed, _): tabs += closed.map(\.tab)
        case let .deleteFolder(_, removal): tabs += removal.closed.map(\.tab)
        case let .deleteSpace(space, _): tabs += space.tabs
        case let .peek(peek, _, _): tabs.append(peek.tab)
        case .edit, .folderToSpace, .spaceToFolder, .move, .createFolder, .spaceEdit, .imported: break
        }
      }
      return Set(tabs.flatMap(\.pages).map(\.id)).union(archive.prefix(Self.archivedSessions).map(\.id))
    }

    // Each window's shown tabs that are favorites; a favorite's page shows in one window at a time.
    struct ShownFavorites: Equatable {
      let space: Space.ID
      let tabs: Set<Tab.ID>
    }

    var shownFavorites: [WindowFeature.State.ID: ShownFavorites] {
      Dictionary(uniqueKeysWithValues: windows.map { window in
        let space = window.spaces.selected
        return (window.id, ShownFavorites(space: space.id, tabs: space.shownTabIDs.filter { space.favorites[id: $0] != nil }))
      })
    }

    // Each profile's favorites, whose leaving every space of the profile has to follow.
    var favoriteIDs: [Profile.ID: Set<Tab.ID>] {
      Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, Set($0.favorites.ids)) })
    }

    // The window showing the tab's page, else the one whose space on screen has the tab (a favorite is in every
    // space of its profile).
    func window(showing tab: Tab.ID) -> WindowFeature.State? {
      let having = windows.filter { $0.spaces.selected.tabs[id: tab] != nil }
      return having.first { $0.spaces.selected.shownTabIDs.contains(tab) } ?? having.first
    }

    var snapshot: Snapshot? {
      guard isLoaded else { return nil }
      return Snapshot(
        profiles: profiles,
        archive: archive,
        windows: windows.filter { !$0.isIncognito }.map {
          Snapshot.Window(id: $0.id, frame: $0.frame, sidebar: $0.sidebar, spaces: $0.spaces)
        } + (closedWindow.map { [$0] } ?? []),
        focusedWindow: focusedWindowID.flatMap { windows[id: $0] }.flatMap { $0.isIncognito ? nil : $0.id }
      )
    }
  }

  enum Action {
    case archiveIdleTabs
    // Adds a profile and moves the spaces to it; their tabs start fresh in it.
    case createProfile(name: String, spaces: Set<Space.ID>)
    case deleteProfile(Profile.ID)
    // Delete unused Profiles: every profile no space uses, Default aside.
    case deleteUnusedProfiles
    case dismissRecoveredSpaces
    case downloads(DownloadsFeature.Action)
    case engine(WebEngineEvent)
    case launched
    // The state could not be read, but a backup could: it is restored with the Today tabs gathered into a
    // "Recently recovered" folder in each space.
    case recovered(Snapshot)
    // Help > Restore Data: the chosen backup replaces the sidebar; the sidebar as it was is backed up first.
    case restoreBackup(Snapshot)
    // The window's frame comes along when the window closed, so ⇧⌘T puts the Little Sailfish back where it was.
    case littleSailfishClosed(LittleSailfishFeature.State.ID, frame: CGRect? = nil)
    case littleSailfishes(IdentifiedActionOf<LittleSailfishFeature>)
    case loaded(Result<Snapshot?, any Error>)
    case newIncognitoWindow
    case newLittleSailfish
    case reopenLittleSailfish
    case newWindow
    // Moves a Little Sailfish's page into a space as its selected tab.
    case openLittleSailfish(LittleSailfishFeature.State.ID, in: Space.ID)
    // Opens a page, such as one of Chrome's settings, in a space using the profile, else in a Little Sailfish.
    case openPage(URL, profile: Profile.ID)
    case openURLs([URL])
    case renameProfile(Profile.ID, name: String)
    case reopen
    case setArchiveAfter(Profile.ID, TimeInterval?)
    // Sparkle downloaded this version, which installs on quit or from the sidebar's pill.
    case updateReady(String)
    case windowClosed(WindowFeature.State.ID)
    case windowFocused(WindowFeature.State.ID)
    case windows(IdentifiedActionOf<WindowFeature>)
  }

  enum CancelID { case save, macTabs }

  // Shared with the quit save, so that every write goes through its lock. Cancelling the in-flight save is
  // only the debounce: cancellable registers inside the effect body, so a save that starts late can cancel a
  // newer one, and whichever survives writes the newest snapshot.
  var writer = SnapshotWriter<Snapshot>.state
  // The tabs whose saved history is kept, through the same kind of writer, so a late save never drops the
  // history of a tab that a newer state refers to.
  let sessionWriter = SnapshotWriter<Set<UUID>>.sessions

  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now
  @Dependency(\.macTabs) var macTabs
  @Dependency(\.persistence) var persistence
  @Dependency(\.requestMediaFolders) var requestMediaFolders
  @Dependency(\.uuid) var uuid
  @Dependency(\.webEngine) var engine

  var body: some ReducerOf<Self> {
    Scope(state: \.downloads, action: \.downloads) {
      DownloadsFeature()
    }
    Reduce { state, action in
      switch action {
      case let .engine(.downloaded(download)):
        return .send(.downloads(.updated(download)))

      // Tidy Downloads' card, with its Undo, and the note once undone show in the window last focused.
      case let .downloads(.renamed(id, file)):
        guard let original = state.downloads.downloads[id: id]?.originalName, let window = state.toastWindowID
        else { return .none }
        return .send(.windows(.element(
          id: window, action: .showToast(file.lastPathComponent, .revertDownloadName(id), placement: .renamed(from: original)))))

      case let .windows(.element(_, .toastAction(.revertDownloadName(id)))):
        return .send(.downloads(.revertName(id)))

      // A login typed into a WebKit page: the window showing its tab, or the last focused one, offers to save it.
      case let .engine(.loginSubmitted(tab, login)):
        guard let window = state.window(showing: tab)?.id ?? state.toastWindowID else {
          return .run { _ in await engine.dropLogin(login.id) }
        }
        let toast = WindowFeature.Action.showToast("Save password for \(login.site)?", .saveLogin(login.id))
        return .send(.windows(.element(id: window, action: toast)))

      case let .windows(.element(_, .toastAction(.saveLogin(id)))):
        return .run { _ in await engine.saveLogin(id) }

      // A tab switched to WebKit for protected video: the window showing it, or the last focused one, offers Undo.
      case let .engine(.openedInWebKit(tab, site)):
        guard let window = state.window(showing: tab)?.id ?? state.toastWindowID else { return .none }
        return .send(.windows(.element(id: window, action: .showToast("\(site) opened in WebKit", .undoEngineSwitch(tab)))))

      case let .windows(.element(_, .toastAction(.undoEngineSwitch(tab)))):
        return .run { _ in await engine.undoEngineSwitch(tab) }

      case .downloads(.reverted):
        guard let window = state.toastWindowID else { return .none }
        return .send(.windows(.element(id: window, action: .showToast("Download name reverted!"))))

      case let .engine(.updated(tab, page)):
        if let littleSailfish = state.littleSailfishes.first(where: { $0.tab?.id == tab }) {
          return .send(.littleSailfishes(.element(id: littleSailfish.id, action: .pageUpdated(page))))
        }
        if let window = state.windows.first(where: { $0.peek?.tab.id == tab }) {
          return .send(.windows(.element(id: window.id, action: .peekUpdated(page))))
        }
        return send(.pageUpdated(tab, page), toSpaceOf: tab, in: state)

      case let .engine(.newWindowRequested(tab, url, background)):
        if state.littleSailfishes.contains(where: { $0.tab?.id == tab }) {
          return open([url], &state)
        }
        if let window = state.windows.first(where: { $0.peek?.tab.id == tab }) {
          return .send(.windows(.element(id: window.id, action: .tab(.open(url), in: window.spaces.selectedID))))
        }
        return send(.openFrom(tab, url, background: background), toSpaceOf: tab, in: state)

      // A Little Sailfish and a Peek open the link in place.
      case let .engine(.peekRequested(tab, url, origin)):
        if let littleSailfish = state.littleSailfishes.first(where: { $0.tab?.id == tab }) {
          return .send(.littleSailfishes(.element(id: littleSailfish.id, action: .open(url))))
        }
        if state.windows.contains(where: { $0.peek?.tab.id == tab }) {
          return .run { _ in await engine.load(tab, url) }
        }
        guard let window = state.window(showing: tab) else {
          return send(.open(url), toSpaceOf: tab, in: state)
        }
        return .send(.windows(.element(id: window.id, action: .peek(url, from: tab, at: origin))))

      case let .engine(.splitRequested(tab, url)):
        if let window = state.windows.first(where: { $0.peek?.tab.id == tab }), let peek = window.peek {
          return .merge(
            .send(.windows(.element(id: window.id, action: .closePeek))),
            .send(.windows(.element(id: window.id, action: .tab(.openInSplit(url, beside: peek.source), in: window.spaces.selectedID))))
          )
        }
        return send(.openInSplit(url, beside: tab), toSpaceOf: tab, in: state)

      // A new Little Sailfish in the page's profile; from a Little Sailfish, a second one beside it.
      case let .engine(.littleSailfishRequested(tab, url)):
        let profile =
          state.littleSailfishes.first { $0.tab?.id == tab }?.profileID
          ?? state.windows.flatMap(\.spaces.spaces).first { $0.tabs[id: tab] != nil }?.profileID
        guard let profile else { return open([url], &state) }
        let id = uuid()
        state.littleSailfishes.append(LittleSailfishFeature.State(id: id, profileID: profile))
        return .send(.littleSailfishes(.element(id: id, action: .open(url))))

      case let .engine(.windowRequested(tab, url, incognito)):
        let profile =
          state.littleSailfishes.first { $0.tab?.id == tab }?.profileID
          ?? state.windows.flatMap(\.spaces.spaces).first { $0.tabs[id: tab] != nil }?.profileID
        guard let profile else { return .none }
        let window = incognito ? incognitoWindow(profile) : makeWindow(state)
        state.windows.append(window)
        return .send(.windows(.element(id: window.id, action: .tab(.open(url), in: window.spaces.selectedID))))

      case let .engine(.closeRequested(tab)):
        if let littleSailfish = state.littleSailfishes.first(where: { $0.tab?.id == tab }) {
          return .send(.littleSailfishClosed(littleSailfish.id))
        }
        if let window = state.windows.first(where: { $0.peek?.tab.id == tab }) {
          return .send(.windows(.element(id: window.id, action: .closePeek)))
        }
        return send(.close(tab), toSpaceOf: tab, in: state)

      // A WebKit page's script popup joins the opener's space, or, from a Peek or a Little Sailfish, the selected space
      // of the frontmost window.
      case let .engine(.adoptRequested(tab, opener, url)):
        if state.windows.contains(where: { $0.spaces.spaces.contains { $0.tabs[id: opener] != nil } }) {
          return send(.adopt(tab, url, active: true), toSpaceOf: opener, in: state)
        }
        guard let id = state.toastWindowID, let window = state.windows[id: id] else { return .none }
        return .send(.windows(.element(id: id, action: .tab(.adopt(tab, url, active: true), in: window.spaces.selectedID))))

      case let .engine(.activateRequested(tab)):
        return send(.select(tab), toSpaceOf: tab, in: state)

      case let .engine(.found(tab, matches, activeMatch)):
        guard let window = state.windows.first(where: { $0.find?.tab == tab }) else { return .none }
        let found = FindFeature.Action.found(matches: matches, activeMatch: activeMatch)
        return .send(.windows(.element(id: window.id, action: .find(.presented(found)))))

      case let .engine(.zoomChanged(tab, percent)):
        guard let window = state.windows.first(where: { $0.spaces.selected.selectedTabID == tab }) else { return .none }
        return .send(.windows(.element(id: window.id, action: .zoomChanged(tab, percent))))

      case .archiveIdleTabs:
        return .merge(
          state.windows.flatMap { window in
            window.spaces.spaces.map { .send(.windows(.element(id: window.id, action: .tab(.archiveIdle, in: $0.id)))) }
          }
        )

      case let .createProfile(name, spaces):
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .none }
        let profile = Profile(id: uuid(), name: name)
        state.$profiles.withLock { _ = $0.append(profile) }
        var closed: [Tab.ID] = []
        var activations: [Effect<Action>] = []
        for window in state.windows where !window.isIncognito {
          for space in window.spaces.spaces where spaces.contains(space.id) {
            state.windows[id: window.id]!.spaces.spaces[id: space.id]!.profileID = profile.id
            // The old profile keeps its favorites, so only the space's own pages start again.
            for tab in space.ownTabs where tab.isLive {
              closed.append(tab.id)
              state.windows[id: window.id]!.spaces.spaces[id: space.id]!.ownTabs[id: tab.id]!.isLive = false
              state.windows[id: window.id]!.spaces.spaces[id: space.id]!.ownTabs[id: tab.id]!.isLoading = false
            }
            // A favorite of the old profile that was shown gives way to the most recently active own tab.
            if let selected = space.selectedTabID, state.windows[id: window.id]!.spaces.spaces[id: space.id]!.tabs[id: selected] == nil {
              state.windows[id: window.id]!.spaces.spaces[id: space.id]!.selectedTabID =
                space.ownTabs.max { $0.lastActiveAt < $1.lastActiveAt }?.id
            }
            if window.spaces.selectedID == space.id {
              activations.append(.send(.windows(.element(id: window.id, action: .tab(.activate, in: space.id)))))
            }
          }
        }
        // The old web contents close before the selected tabs reload in the new profile.
        return .concatenate(
          .run { [closed] _ in
            for tab in closed {
              await engine.close(tab)
            }
          },
          .merge(activations)
        )

      case let .deleteProfile(id):
        guard state.canDeleteProfile(id) else { return .none }
        return deleteProfiles([id], &state)

      case .deleteUnusedProfiles:
        let unused = state.unusedProfiles.map(\.id)
        guard !unused.isEmpty else { return .none }
        return deleteProfiles(unused, &state)

      case .dismissRecoveredSpaces:
        state.recoveredSpaces = []
        return .none

      case .launched:
        return .merge(
          .run { send in
            // Before any tab opens a WebKit store.
            await engine.removeDeletedStores()
            do {
              await send(.loaded(.success(try persistence.load().map { try Snapshot.decode($0) })))
            } catch let error where Self.isUnreadable(error) {
              // A backup that reads is the state to go on from; the file that did not read is set aside first, so
              // the next save does not overwrite the evidence. The listing is a boundary: without it, plain failure.
              for backup in (try? persistence.backups()) ?? [] {
                guard let snapshot = try? Snapshot.decode(persistence.loadBackup(backup)) else { continue }
                // Without the file set aside, saving stays off (isLoaded false), so it is never overwritten.
                do {
                  try persistence.setAside()
                } catch {
                  await send(.loaded(.failure(error)))
                  return
                }
                await send(.recovered(snapshot))
                return
              }
              await send(.loaded(.failure(error)))
            } catch {
              await send(.loaded(.failure(error)))
            }
          },
          .run { send in
            for await event in engine.events() {
              await send(.engine(event))
            }
          }
        )

      case let .loaded(result):
        do {
          let snapshot = try result.get()
          if snapshot == nil, state.onboarding == .undecided {
            state.$onboarding.withLock { $0 = .pending }
          }
          // No saved state, on a new install or after the data folder was wiped, is a first launch.
          if snapshot == nil {
            state.$firstLaunch.withLock { $0 = now }
          }
          apply(snapshot, &state)
          state.isLoaded = true
        } catch {
          Logger().error("State not restored, saving disabled: \(error)")
        }
        return start(&state)

      case let .recovered(snapshot):
        apply(snapshot, &state)
        for window in state.windows {
          for space in window.spaces.spaces {
            state.windows[id: window.id]!.spaces.spaces[id: space.id]!.gatherRecovered(into: uuid())
          }
        }
        state.isLoaded = true
        return start(&state)

      case let .restoreBackup(snapshot):
        // The Shell backed the sidebar up before sending this. Profiles and the archive stay as they are; only
        // the windows come from the backup, and incognito windows, never in a snapshot, stay open.
        guard state.isLoaded else { return .none }
        // Only the replaced windows' pages close; the incognito windows keep theirs.
        let live = state.windows.filter { !$0.isIncognito }.flatMap { window in
          window.spaces.spaces.flatMap { $0.tabs.filter(\.isLive).map(\.id) } + (window.peek.map { [$0.tab.id] } ?? [])
        }
        let incognito = state.windows.filter(\.isIncognito)
        applyWindows(snapshot.windows, &state)
        state.windows.append(contentsOf: incognito)
        return .merge(
          .run { _ in
            for tab in live {
              await engine.close(tab)
            }
          },
          start(&state)
        )

      case .newIncognitoWindow:
        state.windows.append(incognitoWindow(state.windows.last { !$0.isIncognito }?.spaces.selected.profileID ?? uuid()))
        return .none

      case let .littleSailfishClosed(id, frame):
        guard let littleSailfish = state.littleSailfishes.remove(id: id), let tab = littleSailfish.tab else { return .none }
        state.$isLittleSailfishHintShown.withLock { $0 = true }
        state.closedLittleSailfishes.append(
          ClosedLittleSailfish(url: tab.url, profileID: littleSailfish.profileID, frame: frame, closedAt: now))
        return .run { _ in await engine.close(tab.id) }

      case .reopenLittleSailfish:
        guard let closed = state.closedLittleSailfishes.popLast() else { return .none }
        let id = uuid()
        state.littleSailfishes.append(LittleSailfishFeature.State(id: id, profileID: closed.profileID, frame: closed.frame))
        return .send(.littleSailfishes(.element(id: id, action: .open(closed.url))))

      case let .littleSailfishes(.element(id, .delegate(.close))):
        state.littleSailfishes.remove(id: id)
        return .none

      case .newLittleSailfish:
        let profile = littleSailfishProfile(state)
        state.littleSailfishes.append(LittleSailfishFeature.State(id: uuid(), profileID: profile, recents: recentTabs(state, profile)))
        return .none

      // ⌘Enter in a window's command bar opens the row in a Little Sailfish of the space's profile.
      case let .windows(.element(id, .commandBar(.presented(.delegate(.openInLittleSailfish(url)))))):
        guard let window = state.windows[id: id] else { return .none }
        let littleSailfish = uuid()
        state.littleSailfishes.append(LittleSailfishFeature.State(id: littleSailfish, profileID: window.spaces.selected.profileID))
        return .send(.littleSailfishes(.element(id: littleSailfish, action: .open(url))))

      case let .openLittleSailfish(id, space):
        guard let tab = state.littleSailfishes[id: id]?.tab,
          let window = state.windows.first(where: { $0.spaces.spaces[id: space] != nil })
        else { return .none }
        state.littleSailfishes.remove(id: id)
        state.$isLittleSailfishHintShown.withLock { $0 = true }
        return .merge(
          .send(.windows(.element(id: window.id, action: .spaces(.select(space))))),
          .send(.windows(.element(id: window.id, action: .tab(.adopt(tab.id, tab.url, active: true), in: space)))),
          .send(.windows(.element(id: window.id, action: .tab(.pageUpdated(tab.id, tab.page), in: space))))
        )

      case .newWindow:
        return openWindow(&state)

      case let .openPage(url, profile):
        guard let window = state.window(using: profile) else {
          let id = uuid()
          state.littleSailfishes.append(LittleSailfishFeature.State(id: id, profileID: profile))
          return .send(.littleSailfishes(.element(id: id, action: .open(url))))
        }
        let space = window.spaces.selected.profileID == profile
          ? window.spaces.selectedID : window.spaces.spaces.first { $0.profileID == profile }!.id
        return .merge(
          .send(.windows(.element(id: window.id, action: .spaces(.select(space))))),
          .send(.windows(.element(id: window.id, action: .tab(.open(url), in: space))))
        )

      case let .openURLs(urls):
        guard state.pendingURLs == nil else {
          state.pendingURLs! += urls
          return .none
        }
        return open(urls, &state)

      case let .renameProfile(id, name):
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .none }
        state.$profiles.withLock { $0[id: id]?.name = name }
        return .none

      case .reopen:
        return state.pendingURLs == nil && state.windows.isEmpty ? openWindow(&state) : .none

      case let .setArchiveAfter(id, interval):
        state.$profiles.withLock { $0[id: id]?.archiveAfter = interval }
        return .none

      case let .windowFocused(id):
        state.focusedWindowID = id
        return .none

      case let .updateReady(version):
        state.$readyUpdate.withLock { $0 = version }
        return .none

      case let .windowClosed(id):
        guard let window = state.windows.remove(id: id) else { return .none }
        // Incognito tabs never offer to save a login, so only a regular window can close on one.
        guard window.isIncognito else {
          // The last regular window holds the only copy of its spaces, so they stay for the next window.
          if !state.windows.contains(where: { !$0.isIncognito }) {
            state.closedWindow = Snapshot.Window(
              id: window.id, frame: window.frame, sidebar: window.sidebar, spaces: window.spaces)
          }
          guard case let .saveLogin(login) = window.toast?.action else { return .none }
          return .run { _ in await engine.dropLogin(login) }
        }
        let profile = window.spaces.selected.profileID
        let tabs = window.spaces.spaces.flatMap(\.tabs).filter(\.isLive).map(\.id)
        let isLast = !state.windows.contains { $0.isIncognito && $0.spaces.selected.profileID == profile }
        return .run { _ in
          for tab in tabs {
            await engine.close(tab)
          }
          if isLast {
            await engine.closeIncognito(profile)
          }
        }

      case let .windows(.element(_, .createProfile(name, spaces))):
        return .send(.createProfile(name: name, spaces: spaces))

      case let .windows(.element(_, .removeImportedProfiles(ids))):
        let unused = ids.filter(state.canDeleteProfile)
        return unused.isEmpty ? .none : deleteProfiles(unused, &state)

      case .downloads, .littleSailfishes, .windows:
        return .none
      }
    }
    .forEach(\.windows, action: \.windows) {
      WindowFeature()
    }
    .forEach(\.littleSailfishes, action: \.littleSailfishes) {
      LittleSailfishFeature()
    }
    // A favorite's page shows in one window. A window that selects a favorite another window shows takes
    // it, and that window's space goes to its most recently active own tab; the first window keeps it when several
    // show it from the start. A window only passing into a space that last showed the favorite leaves it where it is.
    .onChange(of: \.shownFavorites) { old, new in
      Reduce { state, _ in
        var effects: [Effect<Action>] = []
        var kept: [Tab.ID: WindowFeature.State.ID] = [:]
        for window in state.windows {
          guard let shown = new[window.id] else { continue }
          let switched = old[window.id].map { $0.space != shown.space } ?? false
          for tab in shown.tabs.subtracting(old[window.id]?.tabs ?? []) {
            let elsewhere = state.windows.contains { $0.id != window.id && new[$0.id]?.tabs.contains(tab) == true }
            if switched, elsewhere {
              effects.append(.send(.windows(.element(id: window.id, action: .tab(.yield(tab), in: shown.space)))))
            } else if kept[tab] == nil {
              kept[tab] = window.id
            }
          }
        }
        for (tab, keeper) in kept {
          for other in state.windows where other.id != keeper && new[other.id]?.tabs.contains(tab) == true {
            effects.append(.send(.windows(.element(id: other.id, action: .tab(.yield(tab), in: other.spaces.selectedID)))))
          }
        }
        return .merge(effects)
      }
    }
    // A tab that leaves a profile's favorites leaves every space of the profile but the one it is now a tab of:
    // each space that showed it, in any window, shows its most recently active own tab instead.
    .onChange(of: \.favoriteIDs) { old, new in
      Reduce { state, _ in
        .merge(
          state.windows.flatMap { window in
            window.spaces.spaces.flatMap { space -> [Effect<Action>] in
              old[space.profileID, default: []].subtracting(new[space.profileID] ?? []).compactMap { tab in
                guard space.tabs[id: tab] == nil, space.selectedTabID == tab || space.split(of: tab) != nil else { return nil }
                return .concatenate(
                  .send(.windows(.element(id: window.id, action: .tab(.lost(tab), in: space.id)))),
                  window.spaces.selectedID == space.id ? .send(.windows(.element(id: window.id, action: .tab(.activate, in: space.id)))) : .none
                )
              }
            }
          })
      }
    }
    .onChange(of: \.snapshot) { _, snapshot in
      Reduce { state, _ in
        guard let snapshot else { return .none }
        writer.update(snapshot)
        sessionWriter.update(state.sessionIDs)
        return .run { _ in
          try await clock.sleep(for: .seconds(1))
          try writer.flush()
          await engine.saveSessions()
          try sessionWriter.flush()
        }
        .cancellable(id: CancelID.save, cancelInFlight: true)
      }
    }
    // A newer state's update replaces one still resolving icons, so the publisher gets the states in order.
    .onChange(of: \.macTabs) { _, value in
      Reduce { _, _ in
        guard let value else { return .none }
        return .run { _ in await macTabs.update(value) }
          .cancellable(id: CancelID.macTabs, cancelInFlight: true)
      }
    }
  }

  // A profile goes with its favorites; their pages, live since the last space of the profile went, close first.
  private func deleteProfiles(_ ids: [Profile.ID], _ state: inout State) -> Effect<Action> {
    let live = ids.flatMap { state.profiles[id: $0]?.favorites.filter(\.isLive).map(\.id) ?? [] }
    state.$profiles.withLock { profiles in profiles.removeAll { ids.contains($0.id) } }
    return .run { _ in
      for tab in live {
        await engine.close(tab)
      }
      for id in ids {
        await engine.deleteProfile(id)
      }
    }
  }

  // A state file that is not the state: not JSON, not a snapshot, or one that does not decode. A newer version
  // or a missing migration is left alone.
  private static func isUnreadable(_ error: any Error) -> Bool {
    if let failure = error as? Snapshot.Failure { return failure == .unreadable }
    return error is DecodingError
  }

  // Takes the snapshot's profiles, archive and windows as the state.
  private func apply(_ snapshot: Snapshot?, _ state: inout State) {
    state.$profiles.withLock { $0 = snapshot?.profiles ?? [] }
    state.$archive.withLock { $0 = snapshot?.archive ?? [] }
    var windows = snapshot?.windows ?? []
    // The last focused window is shown last, so it is the key window again.
    if let focused = windows.firstIndex(where: { $0.id == snapshot?.focusedWindow }) {
      windows.append(windows.remove(at: focused))
    }
    applyWindows(windows, &state)
    state.closedWindow = nil
    state.focusedWindowID = snapshot?.focusedWindow
  }

  // Takes the windows as the state's, with spaces of a profile missing here going back to Default.
  private func applyWindows(_ windows: [Snapshot.Window], _ state: inout State) {
    state.windows = IdentifiedArray(
      uniqueElements: windows.map {
        WindowFeature.State(id: $0.id, frame: $0.frame, sidebar: $0.sidebar, spaces: $0.spaces)
      }
    )
    // A space whose profile is missing on this computer goes back to Default.
    if let fallback = state.profiles.first?.id {
      for window in state.windows {
        for space in window.spaces.spaces where state.profiles[id: space.profileID] == nil {
          state.windows[id: window.id]!.spaces.spaces[id: space.id]!.profileID = fallback
          state.recoveredSpaces.append(space.name)
        }
      }
    }
  }

  // Opens the windows' pages once the state is in place, and the URLs that arrived before it.
  private func start(_ state: inout State) -> Effect<Action> {
    if state.windows.isEmpty {
      state.windows.append(makeWindow(state))
    }
    // An install from before the first launch was recorded started with its oldest space.
    if state.firstLaunch == nil {
      state.$firstLaunch.withLock { $0 = state.windows.flatMap(\.spaces.spaces).map(\.createdAt).min() }
    }
    let urls = state.pendingURLs ?? []
    // A launch that opens links shows them alone: the onboarding's sheet would bring its window over a Little Sailfish.
    // It stays pending for the next launch.
    if state.onboarding == .pending, urls.isEmpty {
      let window = state.windows.count - 1
      state.windows[window].importer = .onboarding(spaceName: state.windows[window].spaces.selected.name)
    }
    state.pendingURLs = nil
    // Installs from before onboarding asked for Media's folders, or that never saw it, are asked at their next launch.
    var request = Effect<Action>.none
    if state.onboarding != .pending, !state.mediaFoldersAsked {
      state.$mediaFoldersAsked.withLock { $0 = true }
      request = .run { _ in await requestMediaFolders() }
    }
    return .merge(
      state.windows.map {
        .send(.windows(.element(id: $0.id, action: .tab(.activate, in: $0.spaces.selectedID))))
      } + [open(urls, &state), request]
    )
  }

  // The closed last window with its spaces when there is one, else a new window.
  private func openWindow(_ state: inout State) -> Effect<Action> {
    guard let closed = state.closedWindow else {
      state.windows.append(makeWindow(state))
      return .none
    }
    state.closedWindow = nil
    state.windows.append(WindowFeature.State(id: closed.id, frame: closed.frame, sidebar: closed.sidebar, spaces: closed.spaces))
    return .send(.windows(.element(id: closed.id, action: .tab(.activate, in: closed.spaces.selectedID))))
  }

  // A new window's space uses the last focused space's profile, as a new window opens on that space.
  private func makeWindow(_ state: State) -> WindowFeature.State {
    if state.profiles.isEmpty {
      state.$profiles.withLock { _ = $0.append(Profile(id: uuid(), name: "Default")) }
    }
    let profile = state.focusedSpace.map(\.profileID).flatMap { state.profiles[id: $0]?.id } ?? state.profiles[0].id
    let space = Space(id: uuid(), name: "Space 1", profileID: profile, createdAt: now, icon: Space.primaryIcon)
    return WindowFeature.State(
      id: uuid(), sidebar: .init(), spaces: .init(spaces: [space], selectedID: space.id)
    )
  }

  private func incognitoWindow(_ profile: Profile.ID) -> WindowFeature.State {
    let space = Space(id: uuid(), name: "Incognito", profileID: profile, createdAt: now, isIncognito: true)
    return WindowFeature.State(id: uuid(), sidebar: .init(), spaces: .init(spaces: [space], selectedID: space.id))
  }

  // Links from other apps go where Space Linking routes them: a space's window as a new tab, the last regular
  // window's space (the most recent space), or a Little Sailfish of their own.
  private func open(_ urls: [URL], _ state: inout State) -> Effect<Action> {
    let spaces = Set(state.windows.filter { !$0.isIncognito }.flatMap(\.spaces.spaces.ids))
    return .merge(
      urls.map { url in
        switch state.linkRoutes.destination(for: url, spaces: spaces) {
        case let .space(space):
          let window = state.windows.first { $0.spaces.spaces[id: space] != nil }!
          return .merge(
            .send(.windows(.element(id: window.id, action: .spaces(.select(space))))),
            .send(.windows(.element(id: window.id, action: .tab(.open(url), in: space))))
          )
        case .mostRecentSpace:
          let opened = state.windows.contains { !$0.isIncognito } ? Effect<Action>.none : openWindow(&state)
          let window = state.windows.last { !$0.isIncognito }!
          return .concatenate(
            opened, .send(.windows(.element(id: window.id, action: .tab(.open(url), in: window.spaces.selectedID)))))
        case .littleSailfish:
          let id = uuid()
          state.littleSailfishes.append(LittleSailfishFeature.State(id: id, profileID: littleSailfishProfile(state)))
          return .send(.littleSailfishes(.element(id: id, action: .open(url))))
        }
      }
    )
  }

  // The profile's most recently active open tabs, which an empty Little Sailfish lists as recent pages.
  private func recentTabs(_ state: State, _ profile: Profile.ID) -> [Tab] {
    let spaces = state.windows.filter { !$0.isIncognito }.flatMap(\.spaces.spaces).filter { $0.profileID == profile }
    let tabs = (state.profiles[id: profile]?.favorites.elements ?? []) + spaces.flatMap(\.ownTabs)
    return Array(tabs.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(5))
  }

  // The profile of the last window's space: a Little Sailfish uses the last used one.
  private func littleSailfishProfile(_ state: State) -> Profile.ID {
    if let window = state.windows.last(where: { !$0.isIncognito }) {
      return window.spaces.selected.profileID
    }
    if state.profiles.isEmpty {
      state.$profiles.withLock { _ = $0.append(Profile(id: uuid(), name: "Default")) }
    }
    return state.profiles[0].id
  }

  struct ClosedLittleSailfish: Equatable {
    let url: URL
    let profileID: Profile.ID
    let frame: CGRect?
    let closedAt: Date
  }

  // A favorite is in every space of its profile: the window showing its page takes the action, else the one whose
  // space on screen has it, else the first space that has it.
  private func send(_ action: TabsFeature.Action, toSpaceOf tab: Tab.ID, in state: State) -> Effect<Action> {
    if let window = state.window(showing: tab) {
      return .send(.windows(.element(id: window.id, action: .tab(action, in: window.spaces.selectedID))))
    }
    for window in state.windows {
      if let space = window.spaces.spaces.first(where: { $0.tabs[id: tab] != nil }) {
        return .send(.windows(.element(id: window.id, action: .tab(action, in: space.id))))
      }
    }
    return .none
  }
}
