import AppKit
import ComposableArchitecture

enum Placement: Codable, Equatable, Hashable {
  case favorite
  case pinned
  case folder(UUID)
  case unpinned
}

struct Tab: Codable, Equatable, Identifiable {
  let id: UUID
  var url: URL
  var title: String
  var placement: Placement
  // The URL a pinned tab returns to when closed.
  var pinnedURL: URL?
  // A name and an icon (an SF Symbol or emoji) the user gave the tab.
  var customTitle: String?
  var icon: String?
  let createdAt: Date
  var lastActiveAt: Date
  var favicon: NSImage?
  var isLive = false
  var isLoading = false
  var canGoBack = false
  var canGoForward = false
  var isAudible = false
  var isMuted = false
  var media: PageMedia?
  // The tab it was opened from, selected again when it closes.
  var openerID: Tab.ID?
  // The group a Today tab is in.
  var groupID: TabGroup.ID?
  // The tab's pages once its page has reported them (see `pages`), and the one it shows.
  var savedPages: [PageRecord]?
  var shownPage = 0

  enum CodingKeys: String, CodingKey {
    case id, url, title, placement, pinnedURL, customTitle, icon, createdAt, lastActiveAt, groupID
    case savedPages = "pages", shownPage
  }

  // A tab whose page never reported has one page, Chromium's, under the tab's id.
  var pages: [PageRecord] {
    get { savedPages ?? [PageRecord(id: id, engine: .chromium)] }
    set { savedPages = newValue }
  }
  var engine: PageEngineKind { pages[shownPage].engine }

  var displayTitle: String { customTitle ?? title }
  // A pinned tab that navigated away from its pinned URL.
  var hasLeftPinnedURL: Bool { pinnedURL.map { $0 != url } ?? false }
  // The page whose favicon stands for the tab: a pinned tab that left its site, as for a sign-in page, keeps its
  // pinned page's, as a favorite does.
  var iconPage: URL { pinnedURL.flatMap { $0.host() == url.host() ? nil : $0 } ?? url }
  var pageFavicon: NSImage? { iconPage == url ? favicon : nil }

  var page: WebPage {
    WebPage(
      url: url, title: title, favicon: favicon, isLoading: isLoading, canGoBack: canGoBack, canGoForward: canGoForward,
      isAudible: isAudible, isMuted: isMuted, media: media, pages: pages, shownPage: shownPage)
  }

  mutating func update(_ page: WebPage) {
    // The page's URL is the committed one, so the requested URL shows until loading ends.
    if !page.isLoading {
      url = page.url ?? url
    }
    title = page.title.isEmpty ? title : page.title
    favicon = page.favicon
    isLoading = page.isLoading
    canGoBack = page.canGoBack
    canGoForward = page.canGoForward
    isAudible = page.isAudible
    isMuted = page.isMuted
    media = page.media
    pages = page.pages
    shownPage = page.shownPage
  }
}

// Tabs saved before tabs had pages decode with one Chromium page under the tab's id.
extension Tab {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    url = try container.decode(URL.self, forKey: .url)
    title = try container.decode(String.self, forKey: .title)
    placement = try container.decode(Placement.self, forKey: .placement)
    pinnedURL = try container.decodeIfPresent(URL.self, forKey: .pinnedURL)
    customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
    icon = try container.decodeIfPresent(String.self, forKey: .icon)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    lastActiveAt = try container.decode(Date.self, forKey: .lastActiveAt)
    groupID = try container.decodeIfPresent(TabGroup.ID.self, forKey: .groupID)
    savedPages = try container.decodeIfPresent([PageRecord].self, forKey: .savedPages)
    shownPage = try container.decodeIfPresent(Int.self, forKey: .shownPage) ?? 0
  }
}

// Tabs shown side by side, left to right (or top to bottom in a vertical split), each with its share.
struct Split: Codable, Equatable, Identifiable {
  let id: UUID
  var tabIDs: [Tab.ID]
  var widths: [Double]
  var isVertical = false

  init(id: UUID, tabIDs: [Tab.ID], widths: [Double], isVertical: Bool = false) {
    self.id = id
    self.tabIDs = tabIDs
    self.widths = widths
    self.isVertical = isVertical
  }

  // Splits saved before vertical splits existed have no isVertical.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    tabIDs = try container.decode([Tab.ID].self, forKey: .tabIDs)
    widths = try container.decode([Double].self, forKey: .widths)
    isVertical = try container.decodeIfPresent(Bool.self, forKey: .isVertical) ?? false
  }
}

// Where a favorite goes among the rows left without it: into a row before a column, or a new row (column nil).
struct FavoriteSlot: Hashable {
  var row: Int
  var column: Int?
}

// An archived tab and where it was among the space's own tabs, so that undo can put it back.
struct ClosedTab: Equatable {
  let tab: Tab
  let index: Int
  // Whether it was the shown tab (or a pane of the shown split); undo then shows it again.
  var wasShown = false
  // The group it was in, which undo brings back if it went with its last tab.
  var group: TabGroup?
}

// A name or icon change to a tab or folder, with the value before, so that undo can put it back.
enum SidebarEdit: Equatable {
  case renamed(Tab.ID, from: String?)
  case iconChanged(Tab.ID, from: String?)
  case folderRenamed(Folder.ID, from: String)
  case folderIconChanged(Folder.ID, from: String?)
  case groupRenamed(TabGroup.ID, from: String)
  case groupRecolored(TabGroup.ID, from: TabGroup.Color)
  // Reset Name and Icon took both away at once.
  case reset(Tab.ID, name: String?, icon: String?)
}

// Where every row sat before a move, so that undo can put the rows back without touching their pages.
struct TabLayout: Equatable {
  let tabs: [Tab]
  let folders: [Folder]
  let pinnedOrder: [UUID]
  let favoriteRows: [[Tab.ID]]
  let groups: [TabGroup]

  init(_ space: TabsFeature.State) {
    tabs = space.tabs.elements
    folders = space.folders.elements
    groups = space.groups.elements
    pinnedOrder = space.pinnedOrder
    favoriteRows = space.favoriteRows
  }
}

// A deleted folder with the folders and archived tabs that were in it, so that undo can put it all back.
struct FolderRemoval: Equatable {
  let folders: [Folder]
  let closed: [ClosedTab]
  let pinnedOrder: [UUID]

  var name: String { folders[0].name }
}

struct Folder: Codable, Equatable, Identifiable {
  let id: UUID
  var name: String
  var isOpen = true
  // The pinned section or the folder it is in.
  var placement = Placement.pinned
  var icon: String?
}

@Reducer
struct TabsFeature {
  @ObservableState
  struct State: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var profileID: UUID
    let createdAt: Date
    // The space's own tabs: pinned, in folders and Today. Its favorites are its profile's.
    var ownTabs: IdentifiedArrayOf<Tab> = []
    var folders: IdentifiedArrayOf<Folder> = []
    var splits: IdentifiedArrayOf<Split> = []
    var groups: IdentifiedArrayOf<TabGroup> = []
    // The order of the pinned section's tabs and folders, nested ones included.
    var pinnedOrder: [UUID] = []
    // Clicking the space title's chevron hides the pinned section.
    var isPinnedCollapsed = false
    // Tabs the last action opened or restored, whose rows fade in; any other row arrives at once.
    var arrivals: Set<Tab.ID> = []
    // Hide Space Header: the space's name heading is left out of the sidebar.
    var isHeaderHidden = false
    var selectedTabID: Tab.ID?
    // Multi-selection: the tabs ⌘-clicked or ⇧-clicked together, which the selection menu acts on as one.
    var selection: Set<Tab.ID> = []
    var isIncognito = false
    // Tidy has just sorted the Today tabs, while its broom sweeps.
    var isTidying = false
    // An SF Symbol name or an emoji; empty shows a dot.
    var icon = ""
    var theme = SpaceTheme()
    @Shared(.profiles) var profiles

    enum CodingKeys: String, CodingKey {
      case id, createdAt
      case _name = "name", _profileID = "profileID", _ownTabs = "tabs", _folders = "folders", _splits = "splits", _groups = "groups"
      case _pinnedOrder = "pinnedOrder", _isPinnedCollapsed = "isPinnedCollapsed"
      case _isHeaderHidden = "isHeaderHidden"
      case _selectedTabID = "selectedTabID", _icon = "icon", _theme = "theme"
    }

    // A space starts with its own tabs only; its favorites are the profile's and stay as they are.
    init(
      id: UUID, name: String, profileID: UUID, createdAt: Date, ownTabs: IdentifiedArrayOf<Tab> = [],
      selectedTabID: Tab.ID? = nil, isIncognito: Bool = false, icon: String = "", theme: SpaceTheme = SpaceTheme()
    ) {
      self.id = id
      self.name = name
      self.profileID = profileID
      self.createdAt = createdAt
      self.selectedTabID = selectedTabID
      self.isIncognito = isIncognito
      self.icon = icon
      self.theme = theme
      self.ownTabs = ownTabs
    }

    // The profile's favorites, which every space of the profile shows and changes; an incognito space has none.
    var favorites: IdentifiedArrayOf<Tab> {
      get { isIncognito ? [] : profiles[id: profileID]?.favorites ?? [] }
      set {
        guard !isIncognito, profiles[id: profileID]?.favorites != newValue else { return }
        $profiles.withLock { $0[id: profileID]?.favorites = newValue }
      }
    }

    var favoriteRows: [[Tab.ID]] {
      get { profiles[id: profileID]?.favoriteRows ?? [] }
      set {
        guard profiles[id: profileID]?.favoriteRows != newValue else { return }
        $profiles.withLock { $0[id: profileID]?.favoriteRows = newValue }
      }
    }

    // The tabs the space shows: the profile's favorites, then its own. A tab set to or from favorite moves between
    // the two, and a favorite changed here changes for every space of the profile.
    var tabs: IdentifiedArrayOf<Tab> {
      get {
        var tabs = favorites
        tabs.append(contentsOf: ownTabs)
        return tabs
      }
      set {
        ownTabs = newValue.filter { $0.placement != .favorite }
        favorites = newValue.filter { $0.placement == .favorite }
      }
    }

    // The limits: three favorites to a row and four panes to a split.
    static let favoritesPerRow = 3
    static let maxPanes = 4

    // The rows the user arranged. A favorite added without a place lays them all out again: as few
    // rows as fit three to a row, filled evenly (4 is 2+2, 5 is 3+2).
    var favoriteGrid: [[Tab]] {
      let favorites = favorites
      let rows = favoriteRows.map { $0.compactMap { favorites[id: $0] } }.filter { !$0.isEmpty }
      let placed = Set(rows.joined().map(\.id))
      let added = favorites.filter { !placed.contains($0.id) }
      guard !added.isEmpty else { return rows }
      let all = Array(rows.joined()) + added
      let rowCount = (all.count + Self.favoritesPerRow - 1) / Self.favoritesPerRow
      let perRow = (all.count + rowCount - 1) / rowCount
      return stride(from: 0, to: all.count, by: perRow).map { Array(all[$0..<min($0 + perRow, all.count)]) }
    }

    var selectedTab: Tab? { selectedTabID.flatMap { tabs[id: $0] } }

    // The shown tab and the other panes of its split; an undo of their archive shows them again.
    var shownTabIDs: Set<Tab.ID> {
      Set(split(of: selectedTabID)?.tabIDs ?? selectedTabID.map { [$0] } ?? [])
    }

    // Clear: every Today tab, the shown one included.
    var clearableTabs: [Tab] {
      tabs(in: .unpinned)
    }

    // Clear Unselected Tabs: every Today tab but the shown ones.
    var unselectedTabs: [Tab] {
      let shown = shownTabIDs
      return tabs(in: .unpinned).filter { !shown.contains($0.id) }
    }

    func split(of tab: Tab.ID?) -> Split? {
      splits.first { $0.tabIDs.contains { $0 == tab } }
    }

    func tabs(in placement: Placement) -> [Tab] {
      tabs.filter { $0.placement == placement }
    }

    var sidebarOrder: [Tab] {
      favoriteGrid.flatMap { $0 } + tree().compactMap { if case let .tab(tab) = $0 { tab } else { nil } } + tabs(in: .unpinned)
    }

    // The sidebar order without the rows folded under a collapsed pinned section or a closed folder, which the
    // shown tab never is: what Tab Above and Tab Below step through.
    var visibleOrder: [Tab] {
      var pinned: [Tab] = []
      func visit(_ container: Placement, folded: Bool) {
        for row in rows(in: container) {
          switch row {
          case let .tab(tab):
            if !folded || shownTabIDs.contains(tab.id) { pinned.append(tab) }
          case let .folder(folder):
            visit(.folder(folder.id), folded: folded || !folder.isOpen)
          }
        }
      }
      visit(.pinned, folded: isPinnedCollapsed)
      return favoriteGrid.flatMap { $0 } + pinned + tabs(in: .unpinned).filter { !isFoldedInGroup($0) }
    }

    // The Today tabs above and below a tab's row, which Archive Tabs Above and Below take; a split's other panes
    // belong to its row.
    func todayNeighbors(of id: Tab.ID) -> (above: [Tab.ID], below: [Tab.ID]) {
      let row = Set(split(of: id)?.tabIDs ?? [id])
      let today = tabs(in: .unpinned).map(\.id)
      guard let index = today.firstIndex(of: id) else { return ([], []) }
      return (today[..<index].filter { !row.contains($0) }, today[(index + 1)...].filter { !row.contains($0) })
    }

    // Archive Other Tabs: the Today tabs other than this one and the selected one, with their splits.
    func otherTodayTabs(than id: Tab.ID) -> [Tab.ID] {
      let kept = Set((split(of: id)?.tabIDs ?? [id]) + (split(of: selectedTabID)?.tabIDs ?? selectedTabID.map { [$0] } ?? []))
      return tabs(in: .unpinned).map(\.id).filter { !kept.contains($0) }
    }

    // The multi-selection's tabs in sidebar order; those no longer in the space drop out.
    var selectedTabs: [Tab] {
      sidebarOrder.filter { selection.contains($0.id) }
    }

    // Whether the selection menu and the "… Tabs" menu items apply: more than one tab selected.
    var hasSelection: Bool { selectedTabs.count > 1 }

    // The tabs on screen, top to bottom: a collapsed pinned section and closed folders hide their rows.
    var visibleTabs: [Tab] {
      func shown(in container: Placement) -> [Tab] {
        rows(in: container).flatMap { row -> [Tab] in
          switch row {
          case let .tab(tab): [tab]
          case let .folder(folder): folder.isOpen ? shown(in: .folder(folder.id)) : []
          }
        }
      }
      return favoriteGrid.flatMap { $0 } + (isPinnedCollapsed ? [] : shown(in: .pinned))
        + tabs(in: .unpinned).filter { !isFoldedInGroup($0) }
    }

    // The folder every selected tab is in, else the pinned section: where a folder from a selection is made.
    var selectionContainer: Placement {
      let placements = Set(selectedTabs.map(\.placement))
      if placements.count == 1, case let .folder(folder)? = placements.first { return .folder(folder) }
      return .pinned
    }

    // The sidebar's items for ⌘1-⌘9, a split counting once, by its first pane.
    var sidebarItems: [Tab] {
      sidebarOrder.filter { tab in split(of: tab.id).map { $0.tabIDs[0] == tab.id } ?? true }
    }
  }

  enum Action {
    case activate
    // As activate, once a space switch's strip is nearly at rest: creating a page blocks the main thread for
    // 130-190 ms, which would stall the slide. Selecting another space cancels it.
    case activateAfterSwitch
    // Adds a tab whose web contents the engine created, e.g. for an extension.
    case adopt(Tab.ID, URL, active: Bool)
    // Removes tabs, keeping them in the archive.
    case archive([Tab.ID])
    // Archives Today tabs not shown for the profile's "Archive tabs after".
    case archiveIdle
    case close(Tab.ID)
    // Clear (⇧⌘K): archives every Today tab, the shown one too.
    case clearToday
    // Clear Unselected Tabs: archives the Today tabs but the shown ones.
    case clearUnselected
    case cycle(Int)
    case delegate(Delegate)
    case deleteFolder(Folder.ID)
    case duplicateFolder(Folder.ID)
    // Copies the tab right after itself, or, dropped with ⌥ held, before a row of a placement (nil: its end).
    case duplicate(Tab.ID, to: Placement? = nil, before: UUID? = nil)
    case goBack
    case goForward
    // To a history entry, chosen in a back or forward menu.
    case goToEntry(HistoryEntry)
    case load(Tab.ID, URL)
    // Mutes or unmutes every tab of the space, loaded or not.
    case muteAll(Bool)
    // Moves the tab before another row, or to the end of the placement.
    case move(Tab.ID, Placement, before: UUID?)
    case moveFavorite(Tab.ID, to: FavoriteSlot)
    // Moves the folder into the pinned section or another folder, before a row or last.
    case moveFolder(Folder.ID, Placement, before: UUID?)
    // A new folder is "Untitled" unless named in the New Folder… dialog. With tabs, it is made around them
    // (New Folder from Selection), where the first of them sat.
    case newFolder(_ name: String = "Untitled", in: Placement, with: [Tab.ID] = [])
    // Undoes a folder's creation: the folder goes and its rows go back where they were.
    case undoNewFolder(Folder.ID, TabLayout)
    // Opens the folder and the folders and pinned section around it, as the command bar's folder row does.
    case openFolder(Folder.ID)
    // ⌘-click adds a tab to the multi-selection or takes it out; ⇧-click extends it from the shown tab.
    case toggleSelection(Tab.ID)
    case extendSelection(to: Tab.ID)
    case clearSelection
    case open(URL)
    // A link opened from a tab: in the foreground at the top of Today, or in the background after the tab and the
    // links already opened from it, as ⌘-click and middle-click do.
    case openFrom(Tab.ID, URL, background: Bool = false)
    // Opens a tab beside another in a split view.
    case openInSplit(URL, beside: Tab.ID)
    case pageUpdated(Tab.ID, WebPage)
    // Loads a tab's page without showing it, as a favorite with a preview keeps its page to read from.
    case preload(Tab.ID)
    case reload
    // Points a pinned tab's pinned URL at the page it shows.
    case replacePinnedURL(Tab.ID)
    // The Edit Pinned URL dialog.
    case setPinnedURL(Tab.ID, URL)
    // An empty name goes back to the page's title.
    case rename(Tab.ID, String)
    case resetToPinnedURL(Tab.ID)
    // Reset Name and Icon: the page's own title and favicon again.
    case resetNameAndIcon(Tab.ID)
    // Puts archived tabs back where they were and selects the last.
    case restore([ClosedTab])
    // Puts a deleted folder back with the folders and tabs that were in it.
    case restoreFolder(FolderRemoval)
    // Undoes a name or icon change.
    case revert(SidebarEdit)
    // Undoes a move: rows go back where they were, keeping their pages as they are now.
    case restoreLayout(TabLayout)
    // Expand All Folders and Collapse All Folders.
    case setAllFolders(isOpen: Bool)
    case renameFolder(Folder.ID, String)
    // Moves the divider after a pane to a fraction of the split's width.
    case resizeSplit(Split.ID, divider: Int, position: Double)
    case setFolderIcon(Folder.ID, String?)
    case select(Tab.ID)
    // Focuses the selected split's pane at an index, or the one this many to the side, wrapping around.
    case selectPane(Int)
    case cyclePane(Int)
    // Moves a pane this many places along its split.
    case movePane(Tab.ID, by: Int)
    // Lays the split's panes out top to bottom, or back to left to right.
    case toggleVerticalSplit(Split.ID)
    // Separate Page from Split View: the pane goes back to being its own tab.
    case separate(Tab.ID)
    // Separate All Tabs: the split ends and each pane is a tab again.
    case separateAll(Split.ID)
    // ⌘1-⌘8 select the sidebar's nth item, and ⌘9 (nil) the last.
    case selectSidebarItem(Int?)
    // Separate From Pinned Tab: the page a pinned tab moved on to opens as its own Today tab, and the pinned
    // tab goes back to its pinned URL.
    case separateFromPinned(Tab.ID)
    case setIcon(Tab.ID, String?)
    // Shows a tab beside another (and the other's split) at a pane index, or at the right, and selects it.
    case split(Tab.ID, beside: Tab.ID, at: Int? = nil)
    // Open Page in WebKit or Chromium: the tab's page again in that engine, kept there while it stays on the site.
    case switchEngine(Tab.ID, PageEngineKind)
    case stop
    case toggleMute(Tab.ID)
    case toggleFolder(Folder.ID)
    case togglePinnedSection
    case toggleHeader
    // Pins a Today tab at the end of Pinned, or moves any other tab to the top of Today.
    case togglePin(Tab.ID)
    // Another window shows the favorite now, and a page shows in one window: the space shows its most recently
    // active own tab outside the favorite's split instead, or nothing.
    case yield(Tab.ID)
    // A favorite the space showed left the profile: it leaves the space's split, and the space's selection goes
    // to its most recently active own tab, or nothing. The space shown on screen activates separately.
    case lost(Tab.ID)
    // Dia's tab groups, of Today tabs only. A new group is made where the first of its tabs is.
    case newGroup(with: [Tab.ID])
    // Moves tabs into a group, before one of its tabs or at its end.
    case group([Tab.ID], into: TabGroup.ID, before: Tab.ID? = nil)
    // Takes tabs out of their group, to just below it.
    case removeFromGroup([Tab.ID])
    case renameGroup(TabGroup.ID, String)
    case setGroupColor(TabGroup.ID, TabGroup.Color)
    case toggleGroup(TabGroup.ID)
    // The group goes and its tabs stay where they are.
    case ungroup(TabGroup.ID)
    // Archives the group's tabs together.
    case closeGroup(TabGroup.ID)
    case tidy(Tidy)

    @CasePathable
    enum Delegate {
      // Tabs the user archived, for undo.
      case archived([ClosedTab])
      // Clear's archive, which always gets its toast.
      case cleared([ClosedTab])
      case edited(SidebarEdit)
      case moved(TabLayout)
      case folderDeleted(FolderRemoval)
      // Tabs archived for not being shown for the profile's "Archive tabs after".
      case autoArchived(Int)
      // A folder made, with the layout before it, for undo.
      case folderCreated(Folder.ID, TabLayout)
      // A tab opened behind the shown one, which the "New Tab Created" toast points at while the sidebar is hidden.
      case openedInBackground(Tab.ID)
      // Tidy found nothing to group.
      case tidyMessage(String)
    }
  }

  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid
  @Dependency(\.webEngine) var engine
  @Dependency(\.continuousClock) var clock

  // A switch's strip has about 5 pt left to travel by then (Motion.layout), so the page's creation is not seen.
  static let switchDelay = Duration.milliseconds(180)

  // The page creation a space switch put off, one per space.
  struct PendingActivation: Hashable {
    let space: TabsFeature.State.ID
  }

  var body: some ReducerOf<Self> {
    Reduce(tidy)
    Reduce { state, action in
      // A report to the window changes no rows, so the rows the last action opened still fade in.
      if case .delegate = action {} else if !state.arrivals.isEmpty {
        state.arrivals = []
      }
      switch action {
      case .activate:
        return activate(&state)
      case .activateAfterSwitch:
        // The activate it sends loads whatever is selected by then, at its current URL, so a close, a move or a
        // navigation in the meantime leaves no stray page.
        guard !unloadedSelection(state).isEmpty else { return .none }
        return .run { send in
          try await clock.sleep(for: Self.switchDelay)
          await send(.activate)
        }
        .cancellable(id: PendingActivation(space: state.id), cancelInFlight: true)

      case let .adopt(id, url, active):
        var tab = newTab(id, url)
        tab.isLive = true
        state.tabs.insert(tab, at: 0)
        if active {
          state.selectedTabID = id
        }
        return .none

      case let .archive(ids):
        return archive(ids, &state)

      case .archiveIdle:
        @Shared(.profiles) var profiles
        // Never archives nothing, and a tab playing sound is kept.
        guard let after = profiles[id: state.profileID]?.archiveAfter else { return .none }
        let idle = state.tabs(in: .unpinned).filter {
          $0.id != state.selectedTabID && !$0.isAudible && now.timeIntervalSince($0.lastActiveAt) >= after
        }
        guard !idle.isEmpty else { return .none }
        return .merge(archive(idle.map(\.id), undoable: false, &state), .send(.delegate(.autoArchived(idle.count))))

      case .clearToday:
        let (closed, effect) = remove(state.clearableTabs.map(\.id), &state)
        // With Today emptied, the pinned item last shown shows.
        let pinned = state.tabs.filter { $0.placement.isPinnedSection }.max { $0.lastActiveAt < $1.lastActiveAt }
        let selection = state.selectedTabID == nil ? pinned.map { select($0.id, &state) } ?? .none : .none
        return .merge(effect, selection, closed.isEmpty ? .none : .send(.delegate(.cleared(closed))))

      case .clearUnselected:
        let (closed, effect) = remove(state.unselectedTabs.map(\.id), &state)
        return .merge(effect, closed.isEmpty ? .none : .send(.delegate(.cleared(closed))))

      case let .close(id):
        guard let tab = state.tabs[id: id] else { return .none }
        let next = neighbor(of: id, state)
        unsplit(id, &state)
        // Closing a pane selects the one beside it.
        if state.selectedTabID == id, let next {
          state.selectedTabID = next
        }
        guard let pinnedURL = tab.pinnedURL else { return archive([id], &state) }
        // Closing a pinned tab unloads it and resets it to its pinned URL, with no history.
        var reset = Tab(
          id: id, url: pinnedURL, title: tab.title, placement: tab.placement, pinnedURL: pinnedURL,
          createdAt: tab.createdAt, lastActiveAt: tab.lastActiveAt, favicon: tab.pageFavicon
        )
        // The name and icon the user gave it stay.
        reset.customTitle = tab.customTitle
        reset.icon = tab.icon
        state.tabs[id: id] = reset
        // Nothing is left selected.
        if state.selectedTabID == id {
          state.selectedTabID = nil
        }
        return .merge(.run { _ in await engine.discard(id) }, activate(&state))

      case let .cycle(offset):
        let order = state.visibleOrder
        guard let index = order.firstIndex(where: { $0.id == state.selectedTabID }) else { return .none }
        return select(order[(index + offset + order.count) % order.count].id, &state)

      case let .deleteFolder(id):
        // The tabs and folders inside it are archived; an empty folder just goes.
        guard let folder = state.folders[id: id] else { return .none }
        let rows = [PinnedRow.folder(folder)] + state.tree(.folder(id))
        let folders = rows.compactMap { if case let .folder(folder) = $0 { folder } else { nil } }
        let pinnedOrder = state.pinnedOrder
        let (closed, effect) = remove(rows.compactMap { if case let .tab(tab) = $0 { tab.id } else { nil } }, &state)
        state.folders.removeAll { folder in folders.contains { $0.id == folder.id } }
        state.pinnedOrder.removeAll { id in rows.contains { $0.id == id } }
        guard rows.count > 1 else { return effect }
        return .merge(
          effect, .send(.delegate(.folderDeleted(FolderRemoval(folders: folders, closed: closed, pinnedOrder: pinnedOrder)))))

      case let .duplicateFolder(id):
        // The copy goes right after the folder.
        guard let folder = state.folders[id: id] else { return .none }
        let next = state.rows(in: folder.placement).drop { $0.id != id }.dropFirst().first?.id
        state.place(copyFolder(id, into: nil, &state), before: next)
        return .none

      case let .duplicate(id, target, before):
        guard let index = state.tabs.index(id: id) else { return .none }
        let tab = state.tabs[index]
        let placement = target ?? (tab.placement == .favorite ? .unpinned : tab.placement)
        var copy = Tab(
          id: uuid(), url: tab.url, title: tab.title, placement: placement,
          pinnedURL: placement == .unpinned ? nil : tab.pinnedURL ?? tab.url, createdAt: now, lastActiveAt: now
        )
        copy.customTitle = tab.customTitle
        copy.icon = tab.icon
        copy.favicon = tab.favicon
        if target == nil {
          copy.groupID = tab.groupID
          state.tabs.insert(copy, at: index + 1)
          if placement.isPinnedSection {
            state.place(copy.id, before: state.rows(in: placement).drop { $0.id != id }.dropFirst().first?.id)
          }
        } else {
          state.tabs.insert(copy, at: before.flatMap { state.tabs.index(id: $0) } ?? state.tabs.endIndex)
          if placement.isPinnedSection {
            state.place(copy.id, before: before)
          }
        }
        state.arrivals = [copy.id]
        return select(copy.id, &state)

      case .goBack:
        return navigate(state, engine.goBack)

      case .goForward:
        return navigate(state, engine.goForward)

      case let .goToEntry(entry):
        return navigate(state) { await engine.goToEntry($0, entry) }

      case let .load(id, url):
        guard let tab = state.tabs[id: id] else { return .none }
        let url = url.chromePage
        state.tabs[id: id]?.url = url
        if tab.isLive { return .run { _ in await engine.load(id, url) } }
        return activate(&state)

      case let .move(id, placement, before):
        let layout = TabLayout(state)
        move(id, placement, before: before, &state)
        return moved(from: layout, state)

      case let .moveFavorite(id, slot):
        guard state.tabs[id: id] != nil else { return .none }
        let layout = TabLayout(state)
        var rows = state.favoriteGrid.map { $0.map(\.id).filter { $0 != id } }.filter { !$0.isEmpty }
        if let column = slot.column {
          guard slot.row < rows.count, rows[slot.row].count < State.favoritesPerRow, column <= rows[slot.row].count
          else { return .none }
          rows[slot.row].insert(id, at: column)
        } else {
          guard slot.row <= rows.count else { return .none }
          rows.insert([id], at: slot.row)
        }
        if state.tabs[id: id]?.placement != .favorite {
          unsplit(id, &state)
          move(id, .favorite, before: nil, &state)
        }
        state.favoriteRows = rows
        return moved(from: layout, state)

      case let .moveFolder(id, placement, before):
        guard id != before, placement.isPinnedSection, state.folders[id: id] != nil else { return .none }
        if case let .folder(parent) = placement, state.folder(parent, isWithin: id) { return .none }
        let layout = TabLayout(state)
        state.folders[id: id]?.placement = placement
        state.place(id, before: before)
        return moved(from: layout, state)

      case let .newFolder(name, container, tabs):
        let layout = TabLayout(state)
        let folder = Folder(id: uuid(), name: name, placement: container)
        state.folders.append(folder)
        let selected = tabs.compactMap { state.tabs[id: $0] }
        // Around a selection it takes the first selected row's place; otherwise it goes last in its container.
        let first = state.tree(container).first { row in selected.contains { $0.id == row.id } }?.id
        state.place(folder.id, before: first)
        for tab in selected {
          move(tab.id, .folder(folder.id), before: nil, &state)
        }
        state.selection = []
        return .send(.delegate(.folderCreated(folder.id, layout)))

      case let .undoNewFolder(id, layout):
        guard state.folders[id: id] != nil else { return .none }
        restore(layout, &state)
        state.folders.remove(id: id)
        state.pinnedOrder.removeAll { $0 == id }
        return .none

      case let .openFolder(id):
        var placement = Placement.folder(id)
        while case let .folder(folder) = placement, state.folders[id: folder] != nil {
          state.folders[id: folder]?.isOpen = true
          placement = state.folders[id: folder]!.placement
        }
        state.isPinnedCollapsed = false
        return .none

      case let .toggleSelection(id):
        guard state.tabs[id: id] != nil else { return .none }
        // The shown tab is part of the selection from the start.
        if state.selection.isEmpty, let shown = state.selectedTabID, shown != id {
          state.selection = [shown]
        }
        state.selection.formSymmetricDifference([id])
        return .none

      case let .extendSelection(id):
        // The rows on screen between the shown tab and the clicked one, within the clicked tab's container.
        guard let clicked = state.tabs[id: id] else { return .none }
        let order = state.visibleTabs.filter { $0.placement == clicked.placement }
        guard let end = order.firstIndex(where: { $0.id == id }) else { return .none }
        let anchor = order.firstIndex { $0.id == state.selectedTabID } ?? end
        state.selection.formUnion(order[min(anchor, end)...max(anchor, end)].map(\.id))
        return .none

      case .clearSelection:
        state.selection = []
        return .none

      case .delegate, .tidy:
        return .none

      case let .open(url):
        let tab = newTab(uuid(), url)
        state.tabs.insert(tab, at: 0)
        state.arrivals = [tab.id]
        state.selectedTabID = tab.id
        return activate(&state)

      case let .openInSplit(url, beside):
        guard state.tabs[id: beside] != nil else { return .none }
        let tab = newTab(uuid(), url)
        state.tabs.insert(tab, at: 0)
        return split(tab.id, beside: beside, &state)

      case let .pageUpdated(id, page):
        guard var tab = state.tabs[id: id] else { return .none }
        let old = tab
        tab.update(page)
        if tab != old {
          state.tabs[id: id] = tab
        }
        return .none

      case let .openFrom(opener, url, background):
        var tab = newTab(uuid(), url)
        tab.openerID = opener
        state.arrivals = [tab.id]
        guard background else {
          state.tabs.insert(tab, at: 0)
          return select(tab.id, &state)
        }
        // After the opener if it is in Today, else at the top of Today; after the links it already opened, so they
        // keep the order they were clicked in.
        var index = state.tabs.index(id: opener).flatMap { state.tabs[$0].placement == .unpinned ? $0 + 1 : nil } ?? 0
        while index < state.tabs.count, state.tabs[index].openerID == opener, state.tabs[index].placement == .unpinned {
          index += 1
        }
        tab.isLive = true
        // A link from a grouped tab joins its group, as in Chromium.
        tab.groupID = state.tabs[id: opener]?.groupID
        state.tabs.insert(tab, at: index)
        return .merge(.send(.delegate(.openedInBackground(tab.id))), .run { [tab, profile = state.profileID, incognito = state.isIncognito] _ in
          await engine.create(tab.id, profile, incognito, tab.pages, tab.shownPage)
          await engine.load(tab.id, url)
        })

      case let .preload(id):
        guard let tab = state.tabs[id: id], !tab.isLive else { return .none }
        state.tabs[id: id]?.isLive = true
        return .run { [profile = state.profileID, incognito = state.isIncognito] _ in
          await engine.create(id, profile, incognito, tab.pages, tab.shownPage)
          await engine.load(id, tab.url)
        }

      case .reload:
        return navigate(state, engine.reload)

      case let .replacePinnedURL(id):
        guard let tab = state.tabs[id: id], tab.pinnedURL != nil else { return .none }
        state.tabs[id: id]?.pinnedURL = tab.url
        return .none

      case let .rename(id, name):
        guard let tab = state.tabs[id: id] else { return .none }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.tabs[id: id]?.customTitle = name.isEmpty ? nil : name
        return edited(.renamed(id, from: tab.customTitle), if: state.tabs[id: id]?.customTitle != tab.customTitle)

      case let .setPinnedURL(id, url):
        guard state.tabs[id: id]?.pinnedURL != nil else { return .none }
        state.tabs[id: id]?.pinnedURL = url
        return .none

      case let .resetNameAndIcon(id):
        guard let tab = state.tabs[id: id] else { return .none }
        state.tabs[id: id]?.customTitle = nil
        state.tabs[id: id]?.icon = nil
        return edited(.reset(id, name: tab.customTitle, icon: tab.icon), if: tab.customTitle != nil || tab.icon != nil)

      case let .muteAll(muted):
        let live = state.tabs.filter { $0.isLive && $0.isMuted != muted }.map(\.id)
        for id in state.tabs.ids {
          state.tabs[id: id]?.isMuted = muted
        }
        return .run { _ in for id in live { await engine.setMuted(id, muted) } }

      case let .selectSidebarItem(index):
        let items = state.sidebarItems
        guard let item = index.map({ $0 < items.count ? items[$0] : nil }) ?? items.last else { return .none }
        return select(item.id, &state)

      case let .separateFromPinned(id):
        guard let tab = state.tabs[id: id], tab.hasLeftPinnedURL else { return .none }
        var page = newTab(uuid(), tab.url)
        page.openerID = id
        state.tabs.insert(page, at: 0)
        return .merge(.send(.resetToPinnedURL(id)), select(page.id, &state))

      case let .resetToPinnedURL(id):
        guard let url = state.tabs[id: id]?.pinnedURL else { return .none }
        return .send(.load(id, url))

      case let .restore(closed):
        return restore(closed, &state)

      case let .restoreFolder(removal):
        for folder in removal.folders where state.folders[id: folder.id] == nil {
          state.folders.append(folder)
        }
        // Each row goes back after the row that preceded it, among whatever the order holds now.
        let rows = Set(removal.folders.map(\.id) + removal.closed.map(\.tab.id))
        for (index, id) in removal.pinnedOrder.enumerated() where rows.contains(id) && !state.pinnedOrder.contains(id) {
          let previous = removal.pinnedOrder[..<index].last { state.pinnedOrder.contains($0) }
          state.pinnedOrder.insert(id, at: previous.flatMap { state.pinnedOrder.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        return restore(removal.closed, &state)

      case let .setAllFolders(isOpen):
        for folder in state.folders {
          state.folders[id: folder.id]?.isOpen = isOpen
        }
        return .none

      case let .renameFolder(id, name):
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let folder = state.folders[id: id] else { return .none }
        state.folders[id: id]?.name = name
        return edited(.folderRenamed(id, from: folder.name), if: name != folder.name)

      case let .revert(edit):
        switch edit {
        case let .renamed(id, from): state.tabs[id: id]?.customTitle = from
        case let .iconChanged(id, from): state.tabs[id: id]?.icon = from
        case let .folderRenamed(id, from): state.folders[id: id]?.name = from
        case let .folderIconChanged(id, from): state.folders[id: id]?.icon = from
        case let .groupRenamed(id, from): state.groups[id: id]?.name = from
        case let .groupRecolored(id, from): state.groups[id: id]?.color = from
        case let .reset(id, name, icon):
          state.tabs[id: id]?.customTitle = name
          state.tabs[id: id]?.icon = icon
        }
        return .none

      case let .resizeSplit(id, divider, position):
        guard var split = state.splits[id: id], divider + 1 < split.widths.count else { return .none }
        let start = split.widths[..<divider].reduce(0, +)
        let pair = split.widths[divider] + split.widths[divider + 1]
        let minimum = 0.1
        let left = min(max(position - start, minimum), pair - minimum)
        split.widths[divider] = left
        split.widths[divider + 1] = pair - left
        state.splits[id: id] = split
        return .none

      case let .select(id):
        return select(id, &state)

      case let .selectPane(index):
        guard let panes = state.split(of: state.selectedTabID)?.tabIDs, panes.indices.contains(index) else { return .none }
        return select(panes[index], &state)

      case let .cyclePane(offset):
        guard let panes = state.split(of: state.selectedTabID)?.tabIDs,
          let index = panes.firstIndex(where: { $0 == state.selectedTabID })
        else { return .none }
        return select(panes[(index + offset + panes.count) % panes.count], &state)

      case let .movePane(id, offset):
        guard var split = state.split(of: id), let index = split.tabIDs.firstIndex(of: id),
          split.tabIDs.indices.contains(index + offset)
        else { return .none }
        split.tabIDs.swapAt(index, index + offset)
        split.widths.swapAt(index, index + offset)
        state.splits[id: split.id] = split
        return .none

      case let .separate(id):
        unsplit(id, &state)
        return .none

      case let .toggleVerticalSplit(id):
        state.splits[id: id]?.isVertical.toggle()
        return .none

      case let .separateAll(id):
        state.splits.remove(id: id)
        return .none

      case let .setFolderIcon(id, icon):
        guard let folder = state.folders[id: id] else { return .none }
        state.folders[id: id]?.icon = icon
        return edited(.folderIconChanged(id, from: folder.icon), if: icon != folder.icon)

      case let .setIcon(id, icon):
        guard let tab = state.tabs[id: id] else { return .none }
        state.tabs[id: id]?.icon = icon
        return edited(.iconChanged(id, from: tab.icon), if: icon != tab.icon)
      case let .split(id, beside, index):
        return split(id, beside: beside, at: index, &state)

      case let .switchEngine(id, kind):
        return .run { _ in await engine.switchEngine(id, kind) }

      case .stop:
        return navigate(state, engine.stop)

      case let .toggleMute(id):
        // A tab is muted even before it plays; a tab without a page is muted when it loads.
        guard let tab = state.tabs[id: id] else { return .none }
        state.tabs[id: id]?.isMuted.toggle()
        return tab.isLive ? .run { _ in await engine.setMuted(id, !tab.isMuted) } : .none

      case let .togglePin(id):
        guard let tab = state.tabs[id: id] else { return .none }
        let layout = TabLayout(state)
        if tab.placement == .unpinned {
          move(id, .pinned, before: nil, &state)
        } else {
          move(id, .unpinned, before: state.tabs(in: .unpinned).first?.id, &state)
        }
        return moved(from: layout, state)

      case let .restoreLayout(layout):
        restore(layout, &state)
        return .none

      case .togglePinnedSection:
        state.isPinnedCollapsed.toggle()
        return .none

      case .toggleHeader:
        state.isHeaderHidden.toggle()
        return .none

      case let .toggleFolder(id):
        state.folders[id: id]?.isOpen.toggle()
        return .none

      case let .lost(id):
        guard state.tabs[id: id] == nil else { return .none }
        unsplit(id, &state)
        guard state.selectedTabID == id else { return .none }
        state.selectedTabID = state.ownTabs.max { $0.lastActiveAt < $1.lastActiveAt }?.id
        return .none

      case let .yield(id):
        let shown = state.shownTabIDs
        guard shown.contains(id) else { return .none }
        state.selectedTabID = state.ownTabs.filter { !shown.contains($0.id) }.max { $0.lastActiveAt < $1.lastActiveAt }?.id
        return activate(&state)

      case let .newGroup(ids):
        let members = withSplits(ids, state).filter { state.tabs[id: $0]?.placement == .unpinned }
        guard !members.isEmpty else { return .none }
        let layout = TabLayout(state)
        let group = TabGroup(id: uuid(), name: "Untitled", color: state.nextGroupColor)
        state.groups.append(group)
        for id in members {
          state.ownTabs[id: id]?.groupID = group.id
        }
        state.selection = []
        return moved(from: layout, state)

      case let .group(ids, group, before):
        guard state.groups[id: group] != nil else { return .none }
        let layout = TabLayout(state)
        for id in ids {
          move(id, .unpinned, before: before, &state)
          for id in withSplits([id], state) {
            state.ownTabs[id: id]?.groupID = group
          }
        }
        state.selection = []
        return moved(from: layout, state)

      case let .removeFromGroup(ids):
        let layout = TabLayout(state)
        let leaving = Set(withSplits(ids, state))
        for id in ids {
          guard let group = state.tabs[id: id]?.groupID else { continue }
          let members = Set(state.members(of: group).map(\.id))
          let lastMember = state.tabs.lastIndex { members.contains($0.id) }!
          let below = state.tabs[(lastMember + 1)...].first { $0.placement == .unpinned && !leaving.contains($0.id) }
          move(id, .unpinned, before: below?.id, &state)
        }
        state.selection = []
        return moved(from: layout, state)

      case let .renameGroup(id, name):
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let group = state.groups[id: id] else { return .none }
        state.groups[id: id]?.name = name
        return edited(.groupRenamed(id, from: group.name), if: name != group.name)

      case let .setGroupColor(id, color):
        guard let group = state.groups[id: id] else { return .none }
        state.groups[id: id]?.color = color
        return edited(.groupRecolored(id, from: group.color), if: color != group.color)

      case let .toggleGroup(id):
        state.groups[id: id]?.isOpen.toggle()
        return .none

      case let .ungroup(id):
        let layout = TabLayout(state)
        for tab in state.members(of: id) {
          state.ownTabs[id: tab.id]?.groupID = nil
        }
        return moved(from: layout, state)

      case let .closeGroup(id):
        return archive(state.members(of: id).map(\.id), &state)
      }
    }
    // Runs after every change but a page's, which never touches a group.
    Reduce { state, action in
      if case .pageUpdated = action {} else {
        state.tidyGroups()
      }
      return .none
    }
  }

  // The tabs with the other panes of their splits, which a group takes as one.
  private func withSplits(_ ids: [Tab.ID], _ state: State) -> [Tab.ID] {
    var all: [Tab.ID] = []
    for id in ids.flatMap({ state.split(of: $0)?.tabIDs ?? [$0] }) where !all.contains(id) {
      all.append(id)
    }
    return all
  }

  // Puts the rows back where the layout had them, keeping each page as it is now; rows added since stay, after.
  private func restore(_ layout: TabLayout, _ state: inout State) {
    var tabs: IdentifiedArrayOf<Tab> = []
    for old in layout.tabs {
      guard var tab = state.tabs[id: old.id] else { continue }
      tab.placement = old.placement
      tab.pinnedURL = old.pinnedURL
      tab.groupID = old.groupID
      tabs.append(tab)
    }
    tabs.append(contentsOf: state.tabs.filter { tabs[id: $0.id] == nil })
    state.tabs = tabs
    var folders: IdentifiedArrayOf<Folder> = []
    for old in layout.folders {
      guard var folder = state.folders[id: old.id] else { continue }
      folder.placement = old.placement
      folders.append(folder)
    }
    folders.append(contentsOf: state.folders.filter { folders[id: $0.id] == nil })
    state.folders = folders
    // A group keeps its name and color as they are now; one that went with its last tab comes back.
    var groups = IdentifiedArray(uniqueElements: layout.groups.map { state.groups[id: $0.id] ?? $0 })
    groups.append(contentsOf: state.groups.filter { groups[id: $0.id] == nil })
    state.groups = groups
    state.pinnedOrder = layout.pinnedOrder
    state.favoriteRows = layout.favoriteRows
  }

  // Reports a move that changed the layout, so that the window can put it on the undo stack.
  private func moved(from layout: TabLayout, _ state: State) -> Effect<Action> {
    TabLayout(state) == layout ? .none : .send(.delegate(.moved(layout)))
  }

  // Reports an edit that changed something, so that the window can put it on the undo stack.
  private func edited(_ edit: SidebarEdit, if changed: Bool) -> Effect<Action> {
    changed ? .send(.delegate(.edited(edit))) : .none
  }

  private func newTab(_ id: Tab.ID, _ url: URL) -> Tab {
    let url = url.chromePage
    return Tab(id: id, url: url, title: url.host() ?? url.absoluteString, placement: .unpinned, createdAt: now, lastActiveAt: now)
  }

  // A split moves as one.
  private func move(_ id: Tab.ID, _ placement: Placement, before: UUID?, _ state: inout State) {
    let ids = state.split(of: id)?.tabIDs ?? [id]
    guard before.map({ !ids.contains($0) }) ?? true else { return }
    var moved = ids.compactMap { state.tabs.remove(id: $0) }
    for index in moved.indices {
      moved[index].pinnedURL = placement == .unpinned ? nil : moved[index].pinnedURL ?? moved[index].url
      moved[index].placement = placement
      moved[index].groupID = nil
    }
    state.tabs.insert(contentsOf: moved, at: before.flatMap { state.tabs.index(id: $0) } ?? state.tabs.endIndex)
    if placement.isPinnedSection {
      ids.forEach { state.place($0, before: before) }
    }
  }

  private func split(_ id: Tab.ID, beside other: Tab.ID, at index: Int? = nil, _ state: inout State) -> Effect<Action> {
    guard id != other, state.tabs[id: other] != nil else { return .none }
    let target = state.split(of: other)?.tabIDs ?? [other]
    guard target.contains(id) || target.count < State.maxPanes else { return .none }
    unsplit(id, &state)
    guard var tab = state.tabs.remove(id: id), let anchor = state.tabs[id: other] else { return .none }
    var split = state.split(of: other) ?? Split(id: uuid(), tabIDs: [other], widths: [1])
    // Each pane gets an equal share.
    tab.placement = anchor.placement
    tab.groupID = anchor.groupID
    tab.pinnedURL = anchor.placement == .unpinned ? nil : tab.pinnedURL ?? tab.url
    let index = min(index ?? split.tabIDs.count, split.tabIDs.count)
    // The split's row shows where its first pane is.
    let first = split.tabIDs[0]
    state.tabs.insert(tab, at: index == 0 ? state.tabs.index(id: first)! : state.tabs.index(id: split.tabIDs.last!)! + 1)
    if index == 0, anchor.placement.isPinnedSection {
      state.place(id, before: first)
    }
    split.tabIDs.insert(id, at: index)
    split.widths = Array(repeating: 1 / Double(split.tabIDs.count), count: split.tabIDs.count)
    state.splits[id: split.id] = split
    return select(id, &state)
  }

  // The pane focused when a tab leaves its split: the one to its left, or else to its right.
  private func neighbor(of id: Tab.ID, _ state: State) -> Tab.ID? {
    state.split(of: id).map { split in
      let index = split.tabIDs.firstIndex(of: id)!
      return split.tabIDs[index > 0 ? index - 1 : 1]
    }
  }

  // Takes a tab out of its split; a split left with one tab ends.
  private func unsplit(_ id: Tab.ID, _ state: inout State) {
    guard var split = state.split(of: id), let index = split.tabIDs.firstIndex(of: id) else { return }
    split.tabIDs.remove(at: index)
    let width = split.widths.remove(at: index)
    guard split.tabIDs.count > 1 else {
      state.splits.remove(id: split.id)
      return
    }
    split.widths = split.widths.map { $0 / (1 - width) }
    state.splits[id: split.id] = split
    // The tab goes right after the split's row, so the remaining panes stay side by side and the row stays put.
    guard let tab = state.tabs.remove(id: id), let last = split.tabIDs.compactMap({ state.tabs.index(id: $0) }).max()
    else { return }
    state.tabs.insert(tab, at: last + 1)
    if tab.placement.isPinnedSection {
      let order = state.tree().map(\.id)
      let next = split.tabIDs.compactMap { order.firstIndex(of: $0) }.max().flatMap { order.dropFirst($0 + 1).first { $0 != id } }
      state.place(id, before: next)
    }
  }

  // Copies a folder and everything in it, unloaded, into a container (nil: the folder's own); returns the copy.
  private func copyFolder(_ id: Folder.ID, into container: Placement?, _ state: inout State) -> Folder.ID {
    var copy = state.folders[id: id]!
    let original = copy.placement
    copy = Folder(id: uuid(), name: copy.name, isOpen: copy.isOpen, placement: container ?? original, icon: copy.icon)
    state.folders.append(copy)
    for row in state.rows(in: .folder(id)) {
      switch row {
      case let .tab(tab):
        let duplicate = Tab(
          id: uuid(), url: tab.url, title: tab.title, placement: .folder(copy.id), pinnedURL: tab.pinnedURL,
          customTitle: tab.customTitle, icon: tab.icon, createdAt: now, lastActiveAt: now)
        state.tabs.append(duplicate)
        state.place(duplicate.id, before: nil)
      case let .folder(folder):
        state.place(copyFolder(folder.id, into: .folder(copy.id), &state), before: nil)
      }
    }
    return copy.id
  }

  private func archive(_ ids: [Tab.ID], undoable: Bool = true, _ state: inout State) -> Effect<Action> {
    let (closed, effect) = remove(ids, &state)
    return .merge(effect, undoable && !closed.isEmpty ? .send(.delegate(.archived(closed))) : .none)
  }

  // Takes archived tabs out of the archive and back to their rows, selecting the last.
  private func restore(_ closed: [ClosedTab], _ state: inout State) -> Effect<Action> {
    @Shared(.archive) var archive
    $archive.withLock { $0.removeAll { item in closed.contains { $0.tab.id == item.id } } }
    for group in closed.compactMap(\.group) where state.groups[id: group.id] == nil {
      state.groups.append(group)
    }
    for item in closed.sorted(by: { $0.index < $1.index }) {
      state.ownTabs.insert(item.tab, at: min(item.index, state.ownTabs.count))
    }
    state.arrivals = Set(closed.map(\.tab.id))
    // The one that was shown comes back on screen, or the last one when nothing is shown.
    guard let shown = closed.first(where: \.wasShown) ?? (state.selectedTabID == nil ? closed.last : nil) else { return .none }
    return select(shown.tab.id, &state)
  }

  // What is removed is archived, except in incognito windows. The closed tabs carry their rows for undo.
  private func remove(_ ids: [Tab.ID], _ state: inout State) -> ([ClosedTab], Effect<Action>) {
    @Shared(.archive) var archive
    let removed = Set(ids)
    let shown = state.shownTabIDs
    for id in ids {
      unsplit(id, &state)
    }
    if let selected = state.selectedTab, removed.contains(selected.id) {
      state.selectedTabID = nextSelection(after: selected, skipping: removed, state)
    }
    let live = state.ownTabs.filter { removed.contains($0.id) && $0.isLive }.map(\.id)
    let closed = state.ownTabs.enumerated().filter { removed.contains($1.id) }.map {
      var tab = $1
      tab.isLive = false
      tab.isLoading = false
      return ClosedTab(
        tab: tab, index: $0, wasShown: shown.contains(tab.id), group: tab.groupID.flatMap { state.groups[id: $0] })
    }
    state.ownTabs.removeAll { removed.contains($0.id) }
    state.selection.subtract(removed)
    if !state.isIncognito {
      let archived = closed.reversed().map {
        ArchivedTab(id: $0.tab.id, url: $0.tab.url, title: $0.tab.displayTitle, profileID: state.profileID, archivedAt: now)
      }
      $archive.withLock { $0.insert(contentsOf: archived, at: 0) }
    }
    return (closed, .merge(.run { _ in for tab in live { await engine.close(tab) } }, activate(&state)))
  }

  // Goes back to the tab this one was opened from, else the row above, else the row below.
  private func nextSelection(after tab: Tab, skipping removed: Set<Tab.ID>, _ state: State) -> Tab.ID? {
    if let opener = tab.openerID, !removed.contains(opener), state.tabs[id: opener] != nil { return opener }
    let rows = state.orderedTabs(in: tab.placement)
    let index = rows.firstIndex { $0.id == tab.id }!
    return (rows[..<index].last { !removed.contains($0.id) } ?? rows[(index + 1)...].first { !removed.contains($0.id) })?.id
  }

  private func select(_ id: Tab.ID, _ state: inout State) -> Effect<Action> {
    // A tab's last shown time counts until it is switched away from, for archiving.
    state.selectedTabID.map { state.tabs[id: $0]?.lastActiveAt = now }
    state.selectedTabID = id
    state.selection = []
    state.tabs[id: id]?.lastActiveAt = now
    return activate(&state)
  }

  // Loads the selected tab, and the other panes of its split, which show beside it.
  private func activate(_ state: inout State) -> Effect<Action> {
    let tabs = unloadedSelection(state)
    for tab in tabs {
      state.tabs[id: tab.id]?.isLive = true
    }
    return .merge(tabs.map { tab in
      .run { [profile = state.profileID, incognito = state.isIncognito] _ in
        await engine.create(tab.id, profile, incognito, tab.pages, tab.shownPage)
        if tab.isMuted {
          await engine.setMuted(tab.id, true)
        }
        await engine.load(tab.id, tab.url)
      }
    })
  }

  // The selected tab and the other panes of its split that have no page yet.
  private func unloadedSelection(_ state: State) -> [Tab] {
    let ids = state.split(of: state.selectedTabID)?.tabIDs ?? state.selectedTabID.map { [$0] } ?? []
    return ids.compactMap { state.tabs[id: $0] }.filter { !$0.isLive }
  }

  private func navigate(
    _ state: State, _ operation: @escaping @Sendable (UUID) async -> Void
  ) -> Effect<Action> {
    guard let tab = state.selectedTab, tab.isLive else { return .none }
    return .run { _ in await operation(tab.id) }
  }
}

extension URL {
  // sailfish://settings and the like are Chromium's pages, however the link arrived.
  var chromePage: URL {
    guard scheme?.lowercased() == "sailfish" else { return self }
    return URL(string: "chrome://" + absoluteString.dropFirst("sailfish://".count)) ?? self
  }
}
