import ComposableArchitecture
import Foundation

// The space swipe's commit rule, read when the fingers lift. A trackpad recording bounds it from above: all eleven
// swipes landed, pulls lifted still from 29% of the width on and flicks from 4%, with the strip at 300 pt/s or more. Neither number is crossed the other way in it, so these stay.
extension SharedKey where Self == AppStorageKey<Double>.Default {
  // Fingers still moving the strip's way at least this fast (scroll points per second) land on the neighbor.
  static var swipeCommitSpeed: Self { Self[.appStorage("swipeCommitSpeed"), default: 100] }
  // A pull lifted still lands once it has crossed this much of the sidebar's width (percent).
  static var swipeCommitDistance: Self { Self[.appStorage("swipeCommitDistance"), default: 12] }
}

@Reducer
struct WindowFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let id: UUID
    var frame: CGRect?
    var sidebar: SidebarFeature.State
    var spaces: SpacesFeature.State
    @Presents var commandBar: CommandBarFeature.State?
    @Presents var find: FindFeature.State?
    // The last query, which the find bar opens with again, as in Chrome.
    var findQuery = ""
    @Presents var importer: ImportFeature.State?
    // The Library keeps its pane while closed, so it opens again where it was left. It exists from the
    // start, so even its first opening slides in.
    @Presents var library: LibraryFeature.State? = LibraryFeature.State(pane: .media)
    var isLibraryOpen = false
    // What ⌘Z puts back, last first; WindowController registers each with the window's undo manager.
    var undoStack: [Undo] = []
    // The toast showing, if any: one at a time.
    var toast: Toast?
    // "Quit Sailfish?" over this window, while "Warn before quitting" asks.
    var isConfirmingQuit = false
    // The zoom percent shown over the page after a zoom step, until it fades.
    var zoomIndicator: Int?
    // The tab a New Split command bar puts its page beside.
    var splitBeside: Tab.ID?
    // Peek: a page previewed over the tab it was opened from.
    var peek: Peek?
    // Expand Current Split: the focused pane fills the page area until the selection changes.
    var expandedPane: Tab.ID?
    // The tabs this window showed, most recent first, across its spaces, for ⌃Tab.
    var recentTabs: [Tab.ID] = []
    // An extension the command bar asked to run; the sidebar runs it on the selected page and clears this.
    var extensionToRun: String?
    // While ⌃ is held after ⌃Tab: the recent tabs as they were at the first press, and the one shown now.
    var recentCycle: RecentCycle?
    // The tab left playing sound, whose controls show at the foot of the sidebar until closed or shown again.
    var miniPlayer: Tab.ID?

    var isIncognito: Bool { spaces.selected.isIncognito }
    var isCommandBarOpen: Bool { commandBar != nil }
    // Lists the open tabs of every space of the window but the selected one, which it never offers to switch
    // to, so Enter on its page opens a new tab.
    var newCommandBar: CommandBarFeature.State {
      let selected = spaces.selected
      let others = isIncognito ? [] : spaces.spaces.filter { $0.id != spaces.selectedID }
      // A favorite the selected space shares is listed once, as its own.
      let elsewhere = others.flatMap { space in space.tabs.filter { selected.tabs[id: $0.id] == nil }.map { ($0, space.name) } }
      var listed: Set<Tab.ID> = []
      return CommandBarFeature.State(
        tabs: (selected.tabs.elements + elsewhere.map(\.0)).filter { $0.id != selected.selectedTabID && listed.insert($0.id).inserted }
          .sorted { $0.lastActiveAt > $1.lastActiveAt },
        profile: selected.profileID,
        spaceNames: Dictionary(elsewhere.map { ($0.id, $1) }) { $1 },
        isIncognito: isIncognito
      )
    }

    // The space to act on a tab in: the selected one when it shows the tab (a favorite is in every space of its
    // profile), else the first that does.
    func space(showing tab: Tab.ID) -> Space.ID? {
      spaces.selected.tabs[id: tab] != nil ? spaces.selectedID : spaces.spaces.first { $0.tabs[id: tab] != nil }?.id
    }
  }

  // Closed pages carry when they closed, so ⇧⌘T can tell whether a Little Sailfish closed more recently.
  enum Undo: Equatable {
    case archive(Space.ID, [ClosedTab], at: Date)
    case deleteFolder(Space.ID, FolderRemoval)
    case deleteSpace(Space, at: Int)
    // A closed Peek, whose page comes back with its history.
    case peek(Peek, Space.ID, at: Date)
    case edit(Space.ID, SidebarEdit)
    case folderToSpace(FolderConversion)
    case spaceToFolder(SpaceConversion)
    case move(Space.ID, TabLayout)
    case createFolder(Space.ID, Folder.ID, TabLayout)
    // A space's name, icon or theme edit, titled by what changed.
    case spaceEdit(Space.ID, SpaceEdit, title: String)
    case imported(ArcImportRecord, from: SourceBrowser)

    var name: String {
      switch self {
      case .archive: "Archive Tab"
      case .deleteFolder: "Delete Folder"
      case .deleteSpace: "Delete Space"
      case .peek: "Close Peek"
      case .edit(_, .renamed), .edit(_, .folderRenamed), .edit(_, .groupRenamed): "Rename"
      case .edit(_, .iconChanged), .edit(_, .folderIconChanged): "Change Icon"
      case .edit(_, .groupRecolored): "Change Color"
      case .edit(_, .reset): "Reset Name and Icon"
      case .folderToSpace: "Turn into Space"
      case .spaceToFolder: "Turn into Folder"
      case .move: "Move"
      case .createFolder: "New Folder"
      case let .spaceEdit(_, _, title): title
      case let .imported(_, browser): "Import from \(browser.rawValue)"
      }
    }

    // What ⇧⌘T reopens, and when it closed.
    var closedAt: Date? {
      switch self {
      case let .archive(_, _, at), let .peek(_, _, at): at
      case .deleteFolder, .deleteSpace, .edit, .folderToSpace, .spaceToFolder, .move, .createFolder, .spaceEdit, .imported:
        nil
      }
    }

    var isClosedPage: Bool { closedAt != nil }
  }

  struct RecentCycle: Equatable {
    // The switcher shows the five most recent.
    static let count = 5
    var tabs: [Tab.ID]
    var index = 0

    var tab: Tab.ID { tabs[index] }
  }

  struct Peek: Equatable {
    var tab: Tab
    let source: Tab.ID
    // Where in the source page the Peek grows from and shrinks back to.
    let origin: CGPoint
  }

  enum Action {
    case closePeek
    case closeMiniPlayer
    // The Peek goes because the selection moved on; nothing to undo.
    case dropPeek
    case commandBar(PresentationAction<CommandBarFeature.Action>)
    // Set Profile ▸ New Profile…, which the app adds.
    case createProfile(name: String, spaces: Set<Space.ID>)
    // ⌃Tab steps to older recently shown tabs (⌃⇧Tab back toward newer) while ⌃ is held; releasing ⌃ ends it.
    case cycleRecentTab(older: Bool)
    case endRecentCycle
    // ⌃W in the switcher closes the tab it is on and moves on to the next.
    case closeInRecentCycle
    case editSelectedTab
    // Moves the Peek's page into the space as a tab, or beside its source in a split view.
    case expandPeek(split: Bool)
    case find(PresentationAction<FindFeature.Action>)
    case frameChanged(CGRect)
    case importer(PresentationAction<ImportFeature.Action>)
    case library(PresentationAction<LibraryFeature.Action>)
    // Restores the last closed tab (⇧⌘T).
    case reopenClosedTab
    case restoreArchived(ArchivedTab.ID)
    case runExtension(String)
    case extensionRan
    // The archived tab comes back under a new id once its history is copied to it.
    case archivedHistoryCopied(ArchivedTab.ID, to: Tab.ID)
    // Undo reopens a closed Peek as the same tab, so that its saved history comes back.
    // Undo brings back a closed Peek's tab, with its pages.
    case peek(URL, from: Tab.ID, at: CGPoint, reusing: Tab? = nil)
    case peekUpdated(WebPage)
    case showCommandBar
    // New Split: the command bar, whose page opens beside the selected tab.
    case newSplit
    case showFind
    case showImport
    case showArcImport
    // The profiles an Arc import added, which its undo leaves to the app to remove where no space uses them.
    case removeImportedProfiles([Profile.ID])
    // Edit > Use Selection to Find (⌘E): finds the page's selected text.
    case useSelectionForFind(String)
    case showLibrary(LibraryFeature.Pane)
    // The Library button and Shift-Command-L.
    case toggleLibrary
    // A space's card or one of its rows in the Library: the Library closes on that space, and that tab.
    case openFromLibrary(Space.ID, tab: Tab.ID?)
    case sidebar(SidebarFeature.Action)
    case spaces(SpacesFeature.Action)
    // A two-finger swipe over the sidebar moved this far, then lifted over a sidebar this wide at this speed.
    case swipe(CGFloat)
    case endSwipe(SwipeSurface, width: CGFloat, velocity: CGFloat)
    case undo
    case toggleExpandedPane
    // Clear Archive: empties the archive, which no undo brings back.
    case clearArchive
    // Shows a toast, replacing any showing; it goes after Toast.duration unless another replaces it first.
    case showToast(String, Toast.Action? = nil, tap: Toast.Action? = nil, placement: Toast.Placement = .bottom)
    case dismissToast(Toast.ID)
    case confirmQuit(Bool)
    case toastAction(Toast.Action)
    // View > Zoom In / Zoom Out / Zoom to Actual Size on the selected tab's page, then the percent indicator.
    case zoom(ZoomStep)
    case showZoom(Int)
    case hideZoom
    // The page's zoom changed, from the engine: the indicator showing takes the new percent.
    case zoomChanged(Tab.ID, Int)
    // The sidebar's Update ready pill: installs the downloaded update and relaunches.
    case restartToUpdate

    static func tab(_ action: TabsFeature.Action, in space: Space.ID) -> Self {
      .spaces(.spaces(.element(id: space, action: action)))
    }
  }

  @Dependency(\.appCommands) var appCommands
  @Dependency(\.arcImport) var arcImport

  private struct ToastDismissal: Hashable {
    let window: State.ID
  }

  private struct ZoomDismissal: Hashable {
    let window: State.ID
  }

  // A closed Peek's page closes once it has shrunk away, unless undo brings it back first.
  private struct PeekClose: Hashable {
    let tab: Tab.ID
  }

  // The Library covers the sidebar at this width, its rail and column. A swipe uncovers it twice as fast as the
  // space strip moves, which is half the fingers' speed.
  static let libraryWidth: CGFloat = 417
  // What a two-finger swipe over the sidebar moves, fixed as the gesture begins.
  enum SwipeSurface: Equatable {
    // The spaces' strip, with the Library before the first space and Create a Space past the last.
    case strip
    // The open Library, which the swipe can only close.
    case library
    // The floating sidebar card, which a swipe to the left puts away.
    case card
  }
  static let libraryGain: CGFloat = 2

  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now
  @Dependency(\.updates) var updates
  @Dependency(\.uuid) var uuid
  @Dependency(\.webEngine) var engine

  var body: some ReducerOf<Self> {
    Scope(state: \.sidebar, action: \.sidebar) {
      SidebarFeature()
    }
    Scope(state: \.spaces, action: \.spaces) {
      SpacesFeature()
    }
    .onChange(of: \.spaces.selected.selectedTabID) { shown, selected in
      Reduce { state, _ in
        state.expandedPane = nil
        // A ⌃Tab cycle records only the tab it ends on. The tab shown before counts even if it was showing from the
        // start.
        if state.recentCycle == nil, let selected {
          state.recentTabs.removeAll { $0 == selected }
          if let shown, shown != selected, !state.recentTabs.contains(shown) {
            state.recentTabs.insert(shown, at: 0)
          }
          state.recentTabs.insert(selected, at: 0)
        }
        state.zoomIndicator = nil
        return .merge(
          miniPlayerFollows(&state, shown: shown, selected: selected),
          state.find == nil ? .none : .send(.find(.presented(.close))),
          state.peek == nil ? .none : .send(.dropPeek),
          .cancel(id: ZoomDismissal(window: state.id))
        )
      }
    }
    .onChange(of: \.spaces.selectedID) { _, _ in commandBarFollowsSpace() }
    Reduce { state, action in
      switch action {
      case let .cycleRecentTab(older):
        if state.recentCycle == nil {
          // The tab showing now starts the list, even in a window that has shown no other since it opened.
          if let shown = state.spaces.selected.selectedTabID, state.recentTabs.first != shown {
            state.recentTabs.removeAll { $0 == shown }
            state.recentTabs.insert(shown, at: 0)
          }
          let open = Set(state.spaces.spaces.flatMap(\.tabs.ids))
          let tabs = state.recentTabs.filter(open.contains)
          // With no other tab shown yet, ⌃Tab steps through the sidebar instead.
          guard tabs.count > 1 else { return .send(.tab(.cycle(older ? 1 : -1), in: state.spaces.selectedID)) }
          state.recentCycle = RecentCycle(tabs: Array(tabs.prefix(RecentCycle.count)))
        }
        guard var cycle = state.recentCycle else { return .none }
        // The page stays until ⌃ is released; a tab archived during the cycle is passed over, the step counted from
        // where it was.
        let current = cycle.tab
        let before = cycle.tabs[..<cycle.index].filter { spaceOf($0, state) != nil }.count
        cycle.tabs = cycle.tabs.filter { spaceOf($0, state) != nil }
        guard !cycle.tabs.isEmpty else {
          state.recentCycle = nil
          return .none
        }
        let count = cycle.tabs.count
        if let at = cycle.tabs.firstIndex(of: current) {
          cycle.index = (at + (older ? 1 : -1) + count) % count
        } else {
          cycle.index = (before + (older ? 0 : -1) + count) % count
        }
        state.recentCycle = cycle
        return .none

      case .closeInRecentCycle:
        guard var cycle = state.recentCycle, let space = spaceOf(cycle.tab, state) else { return .none }
        let closing: Tab.ID = cycle.tabs.remove(at: cycle.index)
        if cycle.tabs.isEmpty {
          state.recentCycle = nil
        } else {
          cycle.index = cycle.index % cycle.tabs.count
          state.recentCycle = cycle
        }
        let close: TabsFeature.Action = .close(closing)
        return .send(.tab(close, in: space))

      case .endRecentCycle:
        guard let cycle = state.recentCycle else { return .none }
        state.recentCycle = nil
        guard let space = spaceOf(cycle.tab, state) else { return .none }
        return showTab(cycle.tab, in: space, state)

      case .closePeek:
        if let peek = state.peek, let space = state.space(showing: peek.source) {
          state.undoStack.append(.peek(peek, space, at: now))
        }
        return closePeek(&state)

      case .dropPeek:
        return closePeek(&state)

      case let .expandPeek(split):
        guard let peek = state.peek else { return .none }
        state.peek = nil
        let space = state.spaces.selectedID
        return .concatenate(
          .send(.tab(.adopt(peek.tab.id, peek.tab.url, active: true), in: space)),
          .send(.tab(.pageUpdated(peek.tab.id, peek.tab.page), in: space)),
          split ? .send(.tab(.split(peek.tab.id, beside: peek.source), in: space)) : .none
        )

      case let .peek(url, source, origin, reused):
        let previous = state.peek?.tab.id
        var tab = Tab(
          id: reused?.id ?? uuid(), url: url, title: url.host() ?? url.absoluteString, placement: .unpinned,
          createdAt: now, lastActiveAt: now, isLive: true)
        if let reused {
          tab.pages = reused.pages
          tab.shownPage = reused.shownPage
        }
        state.peek = Peek(tab: tab, source: source, origin: origin)
        return .merge(
          reused.map { .cancel(id: PeekClose(tab: $0.id)) } ?? .none,
          .run { [space = state.spaces.selected, tab] _ in
            if let previous {
              await engine.close(previous)
            }
            await engine.create(tab.id, space.profileID, space.isIncognito, tab.pages, tab.shownPage)
            await engine.load(tab.id, url)
          }
        )

      case let .peekUpdated(page):
        state.peek?.tab.update(page)
        return .none

      case let .commandBar(.presented(.delegate(.run(command)))):
        state.commandBar = nil
        return .run { _ in await appCommands.perform(command) }

      case let .commandBar(.presented(.delegate(delegate))):
        let editing = state.commandBar?.editing
        state.commandBar = nil
        let space = state.spaces.selectedID
        if let beside = state.splitBeside {
          state.splitBeside = nil
          switch delegate {
          case let .open(url): return .send(.tab(.openInSplit(url, beside: beside), in: space))
          case let .selectTab(id): return .send(.tab(.split(id, beside: beside), in: space))
          case .openInLittleSailfish, .run: return .none
          }
        }
        switch delegate {
        // The app opens the Little Sailfish.
        case .openInLittleSailfish: return .none
        case let .open(url):
          guard let editing, let tab = state.spaces.selected.tabs[id: editing] else { return .send(.tab(.open(url), in: space)) }
          // A pinned tab keeps its pinned page: any other one opens in a new Today tab.
          if let pinned = tab.pinnedURL, !url.isSamePage(as: pinned) {
            return .send(.tab(.openFrom(editing, url), in: space))
          }
          return .send(.tab(.load(editing, url), in: space))
        case let .selectTab(id):
          // ⌘L, Enter on the current page: reloads it.
          if id == editing { return .send(.tab(.reload, in: space)) }
          guard let space = state.space(showing: id) else { return .none }
          return .concatenate(
            space == state.spaces.selectedID ? .none : .send(.spaces(.select(space))),
            .send(.tab(.select(id), in: space)))
        case .run: return .none
        }

      case .editSelectedTab:
        state.commandBar = state.newCommandBar
        state.commandBar?.commands = appCommands.available()
        state.splitBeside = nil
        if let tab = state.spaces.selected.selectedTab {
          state.commandBar?.tabs.insert(tab, at: 0)
          state.commandBar?.editing = tab.id
          state.commandBar?.query = tab.url.absoluteString
        }
        state.commandBar?.refreshSuggestions()
        return .none

      case let .spaces(.spaces(.element(id, .delegate(.archived(closed))))):
        push(.archive(id, closed, at: now), &state)
        // Archiving several tabs at once gets a count toast; ⌘W on one tab does not.
        guard closed.count > 1 else { return .none }
        return .send(.showToast(Self.archivedMessage(closed.count), .undo))

      case let .spaces(.spaces(.element(id, .delegate(.cleared(closed))))):
        push(.archive(id, closed, at: now), &state)
        return .send(.showToast("Cleared Tabs! Use ⌘Z to undo."))

      case let .spaces(.delegate(.deleted(space, index))):
        push(.deleteSpace(space, at: index), &state)
        // In the window's corner; ⌘Z undoes it.
        return .send(.showToast("Space deleted! Use ⌘Z to undo.", placement: .corner))

      case let .spaces(.spaces(.element(id, .delegate(.moved(layout))))):
        push(.move(id, layout), &state)
        return .none

      case let .spaces(.spaces(.element(id, .delegate(.edited(edit))))):
        push(.edit(id, edit), &state)
        return .none

      case let .spaces(.spaces(.element(_, .delegate(.autoArchived(count))))):
        // The first one also brings up the Auto Archive banner.
        @Shared(.autoArchiveBanner) var banner
        if banner == .unseen {
          $banner.withLock { $0 = .shown }
        }
        return .send(.showToast(count == 1 ? "Auto archived 1 tab" : "Auto archived \(count) tabs"))

      // The toast after a move to another space takes you to the tab.
      case let .spaces(.moveTab(tab, _, to)):
        guard state.spaces.spaces[id: to]?.tabs[id: tab] != nil else { return .none }
        return .send(.showToast("Tab moved! Click to go there.", tap: .goToTab(tab), placement: .topTrailing))

      case let .spaces(.spaces(.element(id, .delegate(.folderDeleted(removal))))):
        push(.deleteFolder(id, removal), &state)
        return .send(.showToast("Deleted “\(removal.name)”", .undo))

      case let .spaces(.delegate(.folderTurnedIntoSpace(conversion))):
        push(.folderToSpace(conversion), &state)
        let name = state.spaces.spaces[id: conversion.space]?.name ?? ""
        return .send(.showToast("Turned “\(name)” into a Space", .undo))

      case let .spaces(.delegate(.spaceTurnedIntoFolder(conversion))):
        push(.spaceToFolder(conversion), &state)
        return .send(.showToast("Turned “\(conversion.space.name)” into a Folder", .undo))

      case .spaces(.delegate(.movedAcrossProfiles)):
        return .send(.showToast("Each Profile has different browser data, so this webpage might look a little different."))

      case let .runExtension(id):
        state.extensionToRun = id
        return .none

      case .extensionRan:
        state.extensionToRun = nil
        return .none

      case let .spaces(.spaces(.element(id, .delegate(.folderCreated(folder, layout))))):
        push(.createFolder(id, folder, layout), &state)
        return .none

      case let .spaces(.delegate(.edited(id, edit))):
        guard let space = state.spaces.spaces[id: id] else { return .none }
        let title = space.theme != edit.theme ? "Edit Theme" : space.icon != edit.icon ? "Change Icon" : "Rename Space"
        push(.spaceEdit(id, edit, title: title), &state)
        return .none

      case .clearArchive:
        @Shared(.archive) var archive
        $archive.withLock { $0.removeAll() }
        return .send(.showToast("Archive cleared"))

      case let .spaces(.spaces(.element(id, .delegate(.openedInBackground(tab))))):
        // With the sidebar hidden, the "New Tab Created" pill at the page's top right points at the new tab.
        guard state.sidebar.isFloating, id == state.spaces.selectedID else { return .none }
        return .send(.showToast("New Tab Created", tap: .goToTab(tab), placement: .topTrailing))

      case let .spaces(.spaces(.element(_, .delegate(.tidyMessage(message))))):
        return .send(.showToast(message))

      case let .spaces(.spaces(.element(id, .togglePin(tab)))):
        guard let space = state.spaces.spaces[id: id], let placement = space.tabs[id: tab]?.placement else { return .none }
        return .send(.showToast(placement == .pinned ? "Pinned Tab to \(space.name)" : "Un-Pinned Tab from \(space.name)"))

      case let .showToast(message, action, tap, placement):
        let replaced = state.toast
        let toast = Toast(
          id: uuid(), message: message, action: action, tap: tap, placement: placement,
          undoDepth: action == .undo ? state.undoStack.count : nil)
        state.toast = toast
        return .merge(
          dropLogin(of: replaced),
          .run { send in
            try await clock.sleep(for: Toast.duration)
            await send(.dismissToast(toast.id), animation: Motion.layout)
          }
          .cancellable(id: ToastDismissal(window: state.id), cancelInFlight: true))

      case let .dismissToast(id):
        guard let toast = state.toast, toast.id == id else { return .none }
        state.toast = nil
        return .merge(dropLogin(of: toast), .cancel(id: ToastDismissal(window: state.id)))

      case let .zoom(step):
        // With a Peek open the keys zoom its page, not the tab under it.
        guard let tab = state.peek?.tab.id ?? state.spaces.selected.selectedTab.flatMap({ $0.isLive ? $0.id : nil })
        else { return .none }
        return .run { [shown = state.zoomIndicator] send in
          guard let percent = await engine.zoom(tab, step) else { return }
          // A different percent while the indicator shows fades it out before the new one fades in.
          if let shown, shown != percent {
            await send(.hideZoom, animation: Motion.zoomIndicatorOut)
            try await clock.sleep(for: .milliseconds(75))
          }
          await send(.showZoom(percent), animation: Motion.zoomIndicatorIn)
        }

      case let .showZoom(percent):
        state.zoomIndicator = percent
        return .run { send in
          try await clock.sleep(for: ZoomIndicator.duration)
          await send(.hideZoom, animation: Motion.zoomIndicatorOut)
        }
        .cancellable(id: ZoomDismissal(window: state.id), cancelInFlight: true)

      case .hideZoom:
        state.zoomIndicator = nil
        return .none

      case .closeMiniPlayer:
        state.miniPlayer = nil
        return .none

      case .restartToUpdate:
        return .run { _ in await updates.install() }

      case let .zoomChanged(tab, percent):
        guard state.zoomIndicator != nil, (state.peek?.tab.id ?? state.spaces.selected.selectedTabID) == tab
        else { return .none }
        state.zoomIndicator = percent
        return .none

      case let .toastAction(action):
        guard let toast = state.toast else { return .none }
        state.toast = nil
        switch action {
        case .undo:
          // Only while its entry is still the top one; a later undoable action makes the toast just close.
          guard toast.undoDepth == state.undoStack.count else { return .cancel(id: ToastDismissal(window: state.id)) }
          return .merge(.cancel(id: ToastDismissal(window: state.id)), .send(.undo))
        case let .goToTab(tab):
          guard let space = state.spaces.spaces.first(where: { $0.tabs[id: tab] != nil })?.id else {
            return .cancel(id: ToastDismissal(window: state.id))
          }
          return .merge(
            .cancel(id: ToastDismissal(window: state.id)),
            space == state.spaces.selectedID ? .none : .send(.spaces(.select(space))),
            .send(.tab(.select(tab), in: space)))
        case .editShortcut, .revertDownloadName, .saveLogin, .undoEngineSwitch:
          // The window opens the Shortcuts pane; the app renames the download back, saves the login or switches
          // the tab back.
          return .cancel(id: ToastDismissal(window: state.id))
        }

      case let .swipe(delta):
        // The strip follows the fingers at half their speed.
        state.sidebar.swipe = (state.sidebar.swipe ?? 0) + delta / 2
        // Before the first space is the Library.
        if state.library == nil, state.spaces.selectedID == state.spaces.spaces.first?.id {
          state.library = LibraryFeature.State(pane: .media)
        }
        return .none

      case let .endSwipe(surface, width, velocity):
        let offset = state.sidebar.swipe ?? 0
        state.sidebar.swipe = nil
        guard offset != 0 else { return .none }
        // Fingers still moving the strip's way as they lift carry it on; moving back, they return it.
        @Shared(.swipeCommitSpeed) var commitSpeed
        @Shared(.swipeCommitDistance) var commitDistance
        let isFlick = abs(velocity) >= commitSpeed && (velocity < 0) == (offset < 0)
        let isPulledBack = abs(velocity) >= commitSpeed && (velocity < 0) != (offset < 0)
        // The Library comes in, or goes, once the sidebar has slid half its width; there is no flick for it.
        let span = state.sidebar.isFloating ? Self.libraryWidth : state.sidebar.width
        let crossesLibrary = abs(offset) * Self.libraryGain > span / 2
        // A swipe begun on the open Library closes it or leaves it open, and nothing else, whatever it does after.
        if surface == .library {
          state.isLibraryOpen = state.isLibraryOpen && !(offset < 0 && crossesLibrary)
          return .none
        }
        let index = state.spaces.spaces.index(id: state.spaces.selectedID)! - Int(offset.sign == .minus ? -1 : 1)
        // Past the last space, the ring fills and lifting once it is full opens Create a Space.
        if index == state.spaces.spaces.count {
          if -offset >= SidebarFeature.State.createDistance {
            state.sidebar.spaceEditorRequest = true
          }
          return .none
        }
        if index < 0 {
          state.isLibraryOpen = crossesLibrary
          return .none
        }
        // The swipe lands on the neighbor on the slightest gesture: fingers still moving its way as they lift, however
        // short the pull, or a short pull lifted still. Fingers pushing back as they lift return it.
        guard isFlick || abs(offset) > width * commitDistance / 100 && !isPulledBack else { return .none }
        return SpacesFeature().reduce(into: &state.spaces, action: .select(state.spaces.spaces[index].id)).map(Action.spaces)

      case .reopenClosedTab:
        guard let index = state.undoStack.lastIndex(where: \.isClosedPage) else { return .none }
        return undo(state.undoStack.remove(at: index), &state)

      // The archived tab comes back at the top of Today, with its history. It gets a new id, since an undo in
      // any window may still bring back the tab it was; it leaves the archive only once its history is copied,
      // so the history is never pruned in between.
      case let .restoreArchived(id):
        @Shared(.archive) var archive
        guard archive[id: id] != nil else { return .none }
        state.isLibraryOpen = false
        let tab = uuid()
        return .run { send in
          await engine.copySession(id, tab)
          await send(.archivedHistoryCopied(id, to: tab))
        }

      case let .archivedHistoryCopied(id, tab):
        @Shared(.archive) var archive
        guard let archived = $archive.withLock({ $0.remove(id: id) }) else { return .none }
        let restored = Tab(
          id: tab, url: archived.url, title: archived.title, placement: .unpinned, createdAt: now, lastActiveAt: now)
        return .send(.tab(.restore([ClosedTab(tab: restored, index: 0, wasShown: true)]), in: state.spaces.selectedID))

      case let .confirmQuit(isShown):
        state.isConfirmingQuit = isShown
        return .none

      case .toggleExpandedPane:
        let selected = state.spaces.selected.selectedTabID
        guard state.spaces.selected.split(of: selected) != nil else { return .none }
        state.expandedPane = state.expandedPane == nil ? selected : nil
        return .none

      case .undo:
        guard let last = state.undoStack.popLast() else { return .none }
        if state.toast?.action == .undo {
          state.toast = nil
        }
        return undo(last, &state)

      case let .frameChanged(frame):
        state.frame = frame
        return .none

      case .showCommandBar:
        state.commandBar = state.newCommandBar
        state.commandBar?.commands = appCommands.available()
        state.commandBar?.refreshSuggestions()
        state.splitBeside = nil
        return .none

      case .newSplit:
        guard let tab = state.spaces.selected.selectedTabID else { return .send(.showCommandBar) }
        state.commandBar = state.newCommandBar
        state.splitBeside = tab
        return .none

      case .showFind:
        guard state.find == nil, let tab = state.spaces.selected.selectedTab, tab.isLive else { return .none }
        state.find = FindFeature.State(tab: tab.id, query: state.findQuery)
        return state.findQuery.isEmpty ? .none : .send(.find(.presented(.next)))

      case let .useSelectionForFind(text):
        guard state.find != nil else {
          state.findQuery = text
          return .send(.showFind)
        }
        return .send(.find(.presented(.queryChanged(text))))

      case let .find(.presented(.queryChanged(query))):
        state.findQuery = query
        return .none

      case .showImport:
        guard !state.isIncognito else { return .none }
        state.importer = ImportFeature.State()
        return .none

      case .showArcImport:
        guard !state.isIncognito else { return .none }
        state.importer = .arc(folder: arcImport.defaultFolder())
        return .none

      case let .importer(.presented(.delegate(.merge(data, shortcuts, included, browser)))):
        let record = ArcImportFeature.merge(data, shortcuts, included, into: &state.spaces, uuid: uuid, now: now)
        push(.imported(record, from: browser), &state)
        // On first run the imported spaces are the first ones: the empty space the window opened with goes, and
        // the space now first takes its primary icon.
        if state.importer?.isOnboarding == true, let first = record.spaces.first {
          state.spaces.selectedID = first
          state.spaces.spaces.removeAll { !record.spaces.contains($0.id) && $0.ownTabs.isEmpty }
          state.spaces.spaces[0].icon = Space.primaryIcon
        }
        return .merge(
          record.shortcuts.isEmpty ? .none : .run { _ in await arcImport.applyShortcuts() },
          record.spaces.first.map { .send(.spaces(.select($0))) } ?? .none,
          .send(.showToast("Imported from \(browser.rawValue)", .undo))
        )

      case let .importer(.presented(.delegate(.theme(theme, name)))):
        let space = state.spaces.selected
        return .send(.spaces(.update(space.id, name: name ?? space.name, icon: space.icon, theme: theme)))

      case let .showLibrary(pane):
        state.library = LibraryFeature.State(pane: pane)
        state.isLibraryOpen = true
        return .none

      case .toggleLibrary:
        if state.library == nil {
          state.library = LibraryFeature.State(pane: .media)
        }
        state.isLibraryOpen.toggle()
        return .none

      case let .openFromLibrary(space, tab):
        state.isLibraryOpen = false
        return .concatenate(
          space == state.spaces.selectedID ? .none : .send(.spaces(.select(space))),
          tab.map { .send(.tab(.select($0), in: space)) } ?? .none)

      case .library(.dismiss):
        state.isLibraryOpen = false
        return .none

      case .commandBar, .createProfile, .find, .importer, .library, .removeImportedProfiles, .sidebar, .spaces:
        return .none
      }
    }
    .ifLet(\.$commandBar, action: \.commandBar) {
      CommandBarFeature()
    }
    .ifLet(\.$find, action: \.find) {
      FindFeature()
    }
    .ifLet(\.$importer, action: \.importer) {
      ImportFeature()
    }
    .ifLet(\.$library, action: \.library) {
      LibraryFeature()
    }
    // A swipe switches spaces inside the reducer above; a key, a dot or a menu item do it in the spaces scope.
    .onChange(of: \.spaces.selectedID) { _, _ in commandBarFollowsSpace() }
    // Watches the reducers above, where the command bar opens and closes. A hidden sidebar slides out while the
    // command bar is open, its New Tab row lit.
    .onChange(of: \.isCommandBarOpen) { _, isOpen in
      Reduce { state, _ in
        state.sidebar.isPeeking = isOpen && state.sidebar.isFloating
        return .none
      }
    }
  }

  // An open command bar follows a space switch: the other space's tabs, profile and history.
  private func commandBarFollowsSpace() -> some ReducerOf<Self> {
    Reduce { state, _ in
      guard var bar = state.commandBar else { return .none }
      let fresh = state.newCommandBar
      let profileChanged = bar.profile != fresh.profile
      bar.tabs = fresh.tabs
      bar.spaceNames = fresh.spaceNames
      bar.isIncognito = fresh.isIncognito
      bar.profile = fresh.profile
      bar.editing = nil
      if profileChanged {
        bar.matches = []
        bar.matchesQuery = ""
        bar.favicons = [:]
      }
      bar.refreshSuggestions()
      bar.selection = min(bar.selection, max(bar.suggestions.count - 1, 0))
      state.commandBar = bar
      // The matches are for the other profile, or for a ⌘L host query the dropped editing no longer asks.
      return profileChanged || bar.matchesQuery != bar.effectiveQuery ? .send(.commandBar(.presented(.appeared))) : .none
    }
  }

  // The space to show the tab in: the selected one when it has the tab (a favorite is in every space of its profile).
  private func spaceOf(_ tab: Tab.ID, _ state: State) -> Space.ID? {
    state.space(showing: tab)
  }

  // Selects a tab, switching to its space first when it is in another one.
  private func showTab(_ tab: Tab.ID, in space: Space.ID, _ state: State) -> Effect<Action> {
    let switchSpace: Effect<Action> = space == state.spaces.selectedID ? .none : .send(.spaces(.select(space)))
    let select: TabsFeature.Action = .select(tab)
    return .concatenate(switchSpace, .send(.tab(select, in: space)))
  }

  // A save-password toast going unanswered forgets its login.
  private func dropLogin(of toast: Toast?) -> Effect<Action> {
    guard case let .saveLogin(login) = toast?.action else { return .none }
    return .run { _ in await engine.dropLogin(login) }
  }

  static func archivedMessage(_ count: Int) -> String {
    count == 1 ? "Archived 1 tab" : "Archived \(count) tabs"
  }

  // A new entry takes an earlier Undo toast down, since its Undo would no longer be the top one.
  private func push(_ undo: Undo, _ state: inout State) {
    state.undoStack.append(undo)
    if state.toast?.action == .undo {
      state.toast = nil
    }
  }

  private func closePeek(_ state: inout State) -> Effect<Action> {
    guard let peek = state.peek else { return .none }
    state.peek = nil
    // Its page shows while it shrinks away.
    return .run { _ in
      try await clock.sleep(for: .seconds(0.3))
      await engine.close(peek.tab.id)
    }
    .cancellable(id: PeekClose(tab: peek.tab.id))
  }

  private func undo(_ undo: Undo, _ state: inout State) -> Effect<Action> {
    switch undo {
    case let .deleteSpace(space, index):
      return .send(.spaces(.restore(space, at: index)))
    case let .archive(space, closed, _):
      guard state.spaces.spaces[id: space] != nil else { return .none }
      return .merge(.send(.spaces(.select(space))), .send(.tab(.restore(closed), in: space)))
    case let .peek(peek, space, _):
      guard state.spaces.spaces[id: space]?.tabs[id: peek.source] != nil else { return .none }
      return .concatenate(
        .send(.spaces(.select(space))), .send(.tab(.select(peek.source), in: space)),
        .send(.peek(peek.tab.url, from: peek.source, at: peek.origin, reusing: peek.tab)))
    case let .deleteFolder(space, removal):
      guard let name = state.spaces.spaces[id: space]?.name else { return .none }
      return .merge(
        .send(.spaces(.select(space))), .send(.tab(.restoreFolder(removal), in: space)),
        .send(.showToast("Folder restored to \(name)")))
    case let .edit(space, edit):
      guard state.spaces.spaces[id: space] != nil else { return .none }
      return .send(.tab(.revert(edit), in: space))
    case let .folderToSpace(conversion):
      return .send(.spaces(.undoFolderToSpace(conversion)))
    case let .spaceToFolder(conversion):
      return .send(.spaces(.undoSpaceToFolder(conversion)))
    case let .move(space, layout):
      guard state.spaces.spaces[id: space] != nil else { return .none }
      return .merge(.send(.spaces(.select(space))), .send(.tab(.restoreLayout(layout), in: space)))
    case let .createFolder(space, folder, layout):
      guard state.spaces.spaces[id: space]?.folders[id: folder] != nil else { return .none }
      return .merge(.send(.spaces(.select(space))), .send(.tab(.undoNewFolder(folder, layout), in: space)))
    case let .spaceEdit(space, edit, _):
      guard state.spaces.spaces[id: space] != nil else { return .none }
      return .merge(.send(.spaces(.select(space))), .send(.spaces(.revert(space, edit))))
    case let .imported(record, _):
      let tabs = ArcImportFeature.revert(record, in: &state.spaces, now: now)
      return .merge(
        .run { _ in
          for tab in tabs {
            await engine.close(tab)
          }
        },
        record.shortcuts.isEmpty ? .none : .run { _ in await arcImport.applyShortcuts() },
        .send(.spaces(.select(state.spaces.selectedID))),
        record.profiles.isEmpty ? .none : .send(.removeImportedProfiles(record.profiles))
      )
    }
  }
}

extension URL {
  // The same page however it was typed: scheme and host in any case, with or without www., and with or without a
  // trailing slash or fragment.
  func isSamePage(as other: URL) -> Bool {
    func key(_ url: URL) -> String {
      let host = (url.host() ?? "").lowercased()
      let path = url.path(percentEncoded: true)
      return [
        (url.scheme ?? "").lowercased(), host.hasPrefix("www.") ? String(host.dropFirst(4)) : host,
        path.hasSuffix("/") ? String(path.dropLast()) : path, url.query(percentEncoded: true) ?? "",
      ].joined(separator: " ")
    }
    return key(self) == key(other)
  }
}
