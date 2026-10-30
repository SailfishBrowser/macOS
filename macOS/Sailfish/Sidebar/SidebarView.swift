import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
  let store: StoreOf<WindowFeature>
  @Environment(\.displayScale) private var displayScale
  @State private var isMenuOpen = false
  // The "+" menu opens with New Tab highlighted; hovering moves the highlight.
  @State private var menuHighlight = "New Tab"
  @State private var isPillHovered = false
  @State private var isClearHovered = false
  @State private var isTidyHovered = false
  @State private var isHovered = false
  // Read only by the Library button and the download stack, so download ticks do not redraw the sidebar.
  @State private var libraryHover = LibraryHover()
  @State private var isTitleHovered = false
  @State private var isCreatingSpace = false
  // Create Space was pressed: the panel fades over the new space instead of sliding back out.
  @State private var spaceCreated = false
  @State private var isEditingSpace = false
  @State private var editorPicker: SpaceEditor.Opening?
  // Change Space Icon…: the icon popover alone, under that space's title, applied as soon as an icon is picked.
  @State private var pickingIconFor: Space.ID?
  @State private var pickedSpaceIcon = ""
  @Shared(.tabReorderingHaptics) private var tabReorderingHaptics
  @State private var renamingFolder: Folder.ID?
  @Shared(.archive) private var archive
  // A folder just added from the '+' menu, still untitled; Esc on its name takes it away again, as Cancel does.
  @State private var newFolderID: Folder.ID?
  @State private var renamingTab: Tab.ID?
  @State private var renamingGroup: TabGroup.ID?
  @State private var hoveredGroup: TabGroup.ID?
  // The tab or folder whose icon is being picked.
  @State private var iconTab: UUID?
  // Lists a collapsed folder's tabs, with a search field, while the pointer rests on it.
  @State private var hoveredFolder: Folder.ID?
  @State private var peekFolder: Folder.ID?
  @State private var isPeekHovered = false
  @State private var peekMonitor: Any?
  // A right click on a folder opens its preview beside the menu, and the preview stays while the
  // menu is up.
  @State private var rightClickMonitor: Any?
  @State private var menuFolder: Folder.ID?
  // Whether the pointer is on a folder's hover "−", whose click the peek monitor leaves to the button.
  @State private var isFolderMinusHovered = false
  @State private var draftName = ""
  // The icon picked in the open space editor, which the footer's dot shows at once.
  @State private var iconPreview: String?
  @State private var zones = Zones()
  @State private var drag: Drag?
  @State private var dotDrag: DotDrag?
  // The split target the dragged tab has rested on long enough for the row to show its half.
  @State private var splitArmed: DropTarget?
  // Read only by the dot row and the tooltip, so hovering a dot does not redraw the sidebar.
  @State private var dotHover = DotHover()
  @FocusState private var isNameFocused: Bool
  // Dims the sidebar while its window is in the background.
  @Environment(\.controlActiveState) private var controlActiveState
  // Show Full URL in the pill's menu, kept across launches.
  @AppStorage("showsFullURL") private var showsFullURL = false
  @Shared(.swipeCommitDistance) private var commitDistance
  // The row the arrow keys are on after ⌘., which Enter opens: a tab, or a tab group's header.
  @State private var keyRow: UUID?
  // The popup of an extension run from the command bar, shown on the URL pill.
  @State private var commandPopup: ExtensionPopup?
  @FocusState private var isListFocused: Bool
  // The edge of the list past which the selected tab is scrolled, where an indicator shows.
  @State private var selectedOffscreen: VerticalEdge?
  // The list's visible height, which its empty area below the rows fills.
  @State private var listHeight: CGFloat = 0
  // Text, a link or files from outside the app are over the sidebar, bound for the top of Today.
  @State private var isDropTargeted = false
  // A space created in this window, whose New Tab label pulses until its first tab.
  @State private var freshSpace: Space.ID?
  @Shared(.showsPinnedHint) private var showsPinnedHint
  @Shared(.autoArchiveBanner) private var autoArchiveBanner
  @Shared(.readyUpdate) private var readyUpdate
  // The sidebar's width, which each page of the favorites strip takes. It starts at the width the sidebar is
  // about to have: a sidebar sliding in is a fresh view, and a strip laid out at 0 until the first measurement
  // drew the tiles bunched at the edge and moving apart while the sidebar was still on its way.
  @State private var width: CGFloat

  init(store: StoreOf<WindowFeature>) {
    self.store = store
    _width = State(initialValue: store.sidebar.visibleWidth)
  }

  // Tab rows are 36 pt tall at a 41 pt pitch.
  private static let rowGap: CGFloat = 2.5
  // How near the boundary between two tab rows the pointer shows the line there rather than a split: the line
  // went once the pointer was 3-5 pt inside a row, the row's gap being 2.5 pt more.
  private static let lineBand: CGFloat = 6

  private var space: Space { store.spaces.selected }
  // How far a swipe has gone past the last space; a swipe closing the Library never gets there.
  private var overscroll: CGFloat {
    !store.isLibraryOpen && store.spaces.selectedID == store.spaces.spaces.last?.id
      ? max(-(store.sidebar.swipe ?? 0), 0) : 0
  }

  // How much of a swipe moves the strip: past the last space, or past the neighbor's own place, only a little,
  // and none toward the Library, which moves the whole window instead.
  private var stripSwipe: CGFloat {
    let swipe = store.sidebar.swipe ?? 0
    if store.isLibraryOpen || swipe > 0 && store.spaces.selectedID == store.spaces.spaces.first?.id { return 0 }
    if overscroll > 0 { return -overscroll * Self.stripGive }
    let reach = store.sidebar.visibleWidth
    return abs(swipe) > reach ? (reach + (abs(swipe) - reach) * Self.stripGive) * (swipe < 0 ? -1 : 1) : swipe
  }
  // The strip stops at the space the fingers pull in, going at most 7.5 pt past it.
  private static let stripGive: CGFloat = 0.15

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if isEditingSpace {
        spaceEditor.onPreferenceChange(SpaceIconPreview.self) { iconPreview = $0 }
      } else {
        content
        sidebarBanner
        MiniPlayer(store: store)
        if let readyUpdate {
          UpdatePill(version: readyUpdate, theme: space.theme) { store.send(.restartToUpdate) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      footer
    }
    .animation(Motion.layout, value: readyUpdate)
    .overlay(alignment: .topLeading) {
      if case let .into(folder)? = drag?.shownTarget, drag?.isLanding == false, let frame = zones.frames[.folder(folder)] {
        // Fills the whole sidebar width behind the folder the row will go into.
        Color.white.opacity(0.45).frame(height: frame.height).offset(y: frame.minY).allowsHitTesting(false)
      }
    }
    .opacity(controlActiveState == .inactive ? 0.7 : 1)
    .overlay(alignment: .topLeading) {
      // The dragged space dot follows the pointer along the footer, lifted lighter than the current dot.
      if let dotDrag, let frame = zones.frames[.dot(dotDrag.id)], let item = store.spaces.spaces[id: dotDrag.id] {
        SpaceDot(icon: item.icon, isSelected: true, isLifted: true)
          .opacity(0.65)
          .frame(width: frame.width, height: frame.height)
          .offset(x: dotDrag.x - frame.width / 2, y: frame.minY)
          .allowsHitTesting(false)
      }
    }
    .overlay(alignment: .trailing) {
      if !isCreatingSpace {
        CreateSpaceRing(progress: overscroll / SidebarFeature.State.createDistance)
          .animation(store.sidebar.swipe == nil ? Motion.layout : nil, value: overscroll)
      }
    }
    .clipped()
    // The detent: a swipe that would land on the next space when released taps the trackpad as it gets there.
    .sensoryFeedback(.alignment, trigger: swipeLands) { _, lands in lands }
    // Read when the sidebar appears too: a hidden sidebar slides out with the request already set.
    .onChange(of: store.sidebar.tabRenameRequest, initial: true) {
      guard store.sidebar.tabRenameRequest else { return }
      store.send(.sidebar(.tabRenameHandled))
      guard let tab = space.selectedTab else { return }
      rename(tab)
    }
    .onHover { isHovered = $0 }
    .onChange(of: store.sidebar.spaceEditorRequest, initial: true) {
      guard let creating = store.sidebar.spaceEditorRequest else { return }
      isCreatingSpace = creating
      isEditingSpace = !creating
      editorPicker = creating ? nil : .theme
      store.send(.sidebar(.editSpace(creating: nil)))
    }
    .task(id: [hoveredFolder, peekFolder, menuFolder].description + "\(isPeekHovered)") { await peek() }
    .onAppear {
      rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
        guard let folder = hoveredFolder, !folderTabs(folder, in: space).isEmpty else { return event }
        menuFolder = folder
        peekFolder = folder
        return event
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in menuFolder = nil }
    // AppKit closes an open peek on a click outside it and drops that click, so a click on the peeked folder's
    // own row is taken here and toggles the folder.
    .onChange(of: peekFolder) { _, folder in
      peekMonitor.map(NSEvent.removeMonitor)
      peekMonitor = folder.map { folder in
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
          guard hoveredFolder == folder, !isFolderMinusHovered else { return event }
          peekFolder = nil
          withAnimation(Motion.row) { send(.toggleFolder(folder)) }
          return nil
        }
      }
    }
    .onDisappear {
      peekMonitor.map(NSEvent.removeMonitor)
      rightClickMonitor.map(NSEvent.removeMonitor)
    }
    .task(id: drag?.shownTarget) {
      // Shows the half a row will split into only once the dragged tab has rested on it.
      splitArmed = nil
      guard drag?.shownTarget?.isSplit == true, (try? await Task.sleep(for: Motion.splitDwell)) != nil else { return }
      splitArmed = drag?.shownTarget
      tick()
    }
    .task(id: drag?.shownTarget) {
      // Spring-loaded space dots: resting on one during a drag switches to that space.
      guard case let .space(id)? = drag?.shownTarget, (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
      store.send(.spaces(.select(id)))
    }
    .coordinateSpace(.named(Zone.space))
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
      zones.width = $0
      width = $0
    }
    // A floating sidebar stays out while a row is dragged over the page.
    .onChange(of: drag != nil) { _, isDragging in store.send(.sidebar(.dragRow(isDragging))) }
    .environment(\.isDragging, drag != nil || dotDrag != nil)
    // Lifts a row only once the pointer has gone 7-14 pt from where it was pressed.
    .simultaneousGesture(
      DragGesture(minimumDistance: 10, coordinateSpace: .named(Zone.space))
        .onChanged(dragChanged)
        .onEnded { drop(at: $0.location) }
    )
    .overlay(alignment: .bottomLeading) { DownloadStack(hover: libraryHover) }
    .overlay(alignment: .topLeading) {
      // Outside the sidebar's clip, so the copy follows the pointer over the page and a rejected drop flies back from
      // there. On drop it turns opaque in the same frame and settles into the row's new slot; a drop on a split
      // target removes it at once.
      if let drag, drag.drop == nil {
        // Over the Favorites grid the row's copy becomes a tile the size of its placeholder, shrinking about the
        // point it was picked up by, over about 15 frames. That point sits at the copy's origin, so
        // the morph is the only move animated here; the pointer and the landing move the origin.
        let tile = drag.landingSize ?? (drag.shownTarget?.isFavorite == true ? zones.frames[.placeholder]?.size : nil)
        let size = tile ?? drag.frame.size
        let anchor = drag.landing.map { CGPoint(x: $0.x + drag.grab.x * size.width, y: $0.y + drag.grab.y * size.height) } ?? drag.location
        draggedRow(drag, asTile: tile != nil)
          .environment(\.spaceTheme, space.theme)
          .frame(width: size.width, height: size.height)
          // Over the page the row keeps the sidebar's color behind it, so it stays legible.
          .background {
            if !drag.isLanding, drag.location.x > zones.width {
              RoundedRectangle(cornerRadius: 12).fill(store.isIncognito ? Theme.incognitoWindow : LinearGradient(theme: space.theme))
            }
          }
          .opacity(drag.isDropped ? 1 : 0.7)
          // Lifts the copy on a soft shadow that stays until it has settled.
          .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
          .offset(x: -drag.grab.x * size.width, y: -drag.grab.y * size.height)
          .offset(x: anchor.x, y: anchor.y)
          .allowsHitTesting(false)
      }
    }
    .overlay(alignment: .bottomLeading) {
      // Outside the sidebar's clip, so it reaches over the page.
      if drag == nil, dotDrag == nil {
        SpaceTipOverlay(store: store, hover: dotHover)
      }
    }
    .overlay {
      if isMenuOpen {
        ZStack(alignment: .bottomLeading) {
          Color.black.opacity(0.001).onTapGesture { isMenuOpen = false }
          newItemMenu.padding(.leading, 6).padding(.bottom, 54).environment(\.colorScheme, .dark)
            // The menu scales in from its corner.
            .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
        }
      }
    }
    .animation(Motion.menu, value: isMenuOpen)
  }

  // The Auto Archive banner, from the first idle archive until it is closed.
  @ViewBuilder private var sidebarBanner: some View {
    if autoArchiveBanner == .shown, !store.isIncognito, let after = store.spaces.profiles[id: space.profileID]?.archiveAfter {
      AutoArchiveBannerView(after: after) { $autoArchiveBanner.withLock { $0 = .dismissed } }
    }
  }

  private var content: some View {
    GeometryReader { outer in
      ZStack(alignment: .topLeading) {
        VStack(alignment: .leading, spacing: 0) {
          searchPill.padding(.horizontal, 8)
          if !store.isIncognito {
            favoritesStrip
          }
          // Keeps the pill and the favorites still and slides the spaces' own sections side by side, each
          // from the same top.
          GeometryReader { proxy in
            let index = store.spaces.spaces.index(id: store.spaces.selectedID) ?? 0
            HStack(spacing: 0) {
              ForEach(store.spaces.spaces) { space in
                SpacePage(store: store, id: space.id) { page($0) }
                  .frame(width: proxy.size.width, height: proxy.size.height)
                  .environment(\.isSelectedSpace, space.id == store.spaces.selectedID)
                  // Only the space on screen takes clicks: a row of the one sliding out is not a row of the shown
                  // space.
                  .allowsHitTesting(space.id == store.spaces.selectedID)
              }
            }
            // The strip follows the fingers during a swipe and settles with the switch's curve once they lift.
            .offset(x: -CGFloat(index) * proxy.size.width + stripSwipe)
            .animation(store.sidebar.swipe == nil ? Motion.swipeSettle : Motion.swipeTrack, value: store.sidebar.swipe)
            .animation(spaceCreated ? nil : Motion.layout, value: index)
          }
          .clipped()
        }
        .frame(width: outer.size.width, height: outer.size.height, alignment: .top)
        // The Create a Space panel is the page after the last space: it comes in from the right and pushes the
        // space's section out to the left with the switch's spring. Cancelled, it goes back the same way;
        // created, it fades over the new space, which is already in place.
        .offset(x: isCreatingSpace ? -outer.size.width : 0)
        .animation(spaceCreated ? nil : Motion.layout, value: isCreatingSpace)
        if isCreatingSpace {
          createPanel
            .frame(width: outer.size.width, height: outer.size.height)
            .transition(spaceCreated ? .opacity : .move(edge: .trailing))
        }
      }
      .animation(Motion.layout, value: isCreatingSpace)
      .clipped()
    }
    // Dropped text, links and files open at the top of Today, where the line shows while they are over the sidebar.
    .sidebarDrop(isTargeted: $isDropTargeted) { urls in
      // Each opens at the top, so the last goes first to keep the dropped order.
      withAnimation(Motion.layout) { urls.reversed().forEach { send(.open($0)) } }
    }
    // Keyboard navigation: ⌘. moves focus here, ↑/↓ move between the shown tabs and Enter opens one.
    .focusable(keyRow != nil)
    .focused($isListFocused)
    .focusEffectDisabled()
    // Only while the list itself has focus, never while a rename field below it is editing.
    .onKeyPress(.upArrow) { isListFocused ? moveKeyRow(-1) : .ignored }
    .onKeyPress(.downArrow) { isListFocused ? moveKeyRow(1) : .ignored }
    .onKeyPress(.return) {
      guard isListFocused, let keyRow else { return .ignored }
      if space.groups[id: keyRow] != nil {
        withAnimation(Motion.row) { send(.toggleGroup(keyRow)) }
        return .handled
      }
      send(.select(keyRow))
      isListFocused = false
      return .handled
    }
    // ← closes the group of the row the keys are on, which they move to; → opens it.
    .onKeyPress(.leftArrow) { isListFocused ? foldKeyRowGroup(open: false) : .ignored }
    .onKeyPress(.rightArrow) { isListFocused ? foldKeyRowGroup(open: true) : .ignored }
    .onKeyPress(.escape) {
      guard isListFocused else { return .ignored }
      isListFocused = false
      return .handled
    }
    .onChange(of: isListFocused) { if !isListFocused { keyRow = nil } }
    .onChange(of: store.sidebar.focusRequests) {
      keyRow = space.selectedTabID ?? navigableRows(space).first
      Task { isListFocused = true }
    }
  }

  // Neighboring spaces of one profile, which share a favorites grid.
  private var profileRuns: [[Space]] {
    store.spaces.spaces.reduce(into: [[Space]]()) { runs, space in
      if runs.last?.last?.profileID == space.profileID {
        runs[runs.count - 1].append(space)
      } else {
        runs.append([space])
      }
    }
  }

  // Favorites belong to the profile: the grid holds still while the spaces of one profile slide below it,
  // and slides along with the space only when the profile changes.
  private var favoritesStrip: some View {
    let runs = profileRuns
    let index = runs.firstIndex { $0.contains { $0.id == store.spaces.selectedID } } ?? 0
    // A swipe toward a space of another profile, or past the last space, carries the grid along.
    let spaces = store.spaces.spaces
    let swipe = store.sidebar.swipe ?? 0
    let neighbor = spaces.index(id: store.spaces.selectedID).map { $0 + (swipe > 0 ? -1 : 1) }
      .flatMap { spaces.indices.contains($0) ? spaces[$0] : nil }
    let follows = swipe != 0 && neighbor.map { $0.profileID != space.profileID } ?? true
    return HStack(alignment: .top, spacing: 0) {
      ForEach(runs, id: \.[0].id) { run in
        let isSelected = run.contains { $0.id == store.spaces.selectedID }
        favorites(run.first { $0.id == store.spaces.selectedID } ?? run[0])
          .padding(.top, 8)
          .padding(.horizontal, 8)
          // Tiles close up under a dropped one with the row motion, otherwise with the layout move.
          .animation(drag?.isDropped == true ? Motion.row : Motion.layout, value: space.favoriteGrid.joined().map(\.id))
          .frame(width: width, alignment: .top)
          // The strip is as tall as the grid on screen; another profile's grid shows past its frame while it slides.
          .frame(height: isSelected ? nil : 0, alignment: .top)
          .environment(\.isSelectedSpace, isSelected)
          // Only the grid on screen takes clicks, so a tile of a profile sliding out never takes one.
          .allowsHitTesting(isSelected)
      }
    }
    .offset(x: -CGFloat(index) * width + (follows ? stripSwipe : 0))
    .animation(store.sidebar.swipe == nil ? Motion.swipeSettle : Motion.swipeTrack, value: store.sidebar.swipe)
    .animation(spaceCreated ? nil : Motion.layout, value: index)
    .frame(width: width, alignment: .leading)
    .clipped()
  }

  // The rows the arrow keys visit, in sidebar order: favorites, then every tab and group header not folded away.
  private func navigableRows(_ space: Space) -> [UUID] {
    space.favoriteGrid.flatMap { $0 }.map(\.id)
      + listItems(space).compactMap { item in
        switch item {
        case let .tab(tab, _, isFolded): isFolded ? nil : tab.id
        case let .group(group): group.id
        default: nil
        }
      }
  }

  private func moveKeyRow(_ offset: Int) -> KeyPress.Result {
    let rows = navigableRows(space)
    guard !rows.isEmpty else { return .ignored }
    let index = keyRow.flatMap { rows.firstIndex(of: $0) }
    keyRow = rows[index.map { min(max($0 + offset, 0), rows.count - 1) } ?? 0]
    return .handled
  }

  private func foldKeyRowGroup(open: Bool) -> KeyPress.Result {
    guard let keyRow, let group = space.groups[id: keyRow] ?? space.tabs[id: keyRow]?.groupID.flatMap({ space.groups[id: $0] })
    else { return .ignored }
    self.keyRow = group.id
    if group.isOpen != open {
      withAnimation(Motion.row) { send(.toggleGroup(group.id)) }
    }
    return .handled
  }

  private func page(_ space: Space) -> some View {
    let items = listItems(space)
    return VStack(alignment: .leading, spacing: 0) {
      if store.isIncognito {
        incognitoLabel.padding(.top, 10)
      } else {
        if !space.isHeaderHidden {
          // Centers the title 26 pt below the favorites.
          spaceTitle(space).zone(.title, $zones).padding(.top, 8)
        }
        // The hint in a space with nothing pinned yet.
        if space.rows(in: .pinned).isEmpty, showsPinnedHint {
          PinnedHint(theme: space.theme) { $showsPinnedHint.withLock { $0 = false } }.padding(.top, 8)
            .zone(.pinnedHint, $zones)
        }
      }
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            ForEach(items) { listItem($0, in: space) }
            // The empty sidebar below the last row: opens a new tab on a double click and shows the sidebar
            // menu on a right click; a drag moves the window, as the rest of the background does.
            Color.clear.frame(maxHeight: .infinity).contentShape(Rectangle())
              .gesture(WindowDragGesture())
              .allowsWindowActivationEvents(true)
              .onTapGesture(count: 2) { store.send(.showCommandBar) }
              .contextMenu { emptySidebarMenu }
          }
          .frame(maxWidth: .infinity, minHeight: listHeight, alignment: .top)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { listHeight = $1 }
        .overlay(alignment: selectedOffscreen == .top ? .top : .bottom) { overflowIndicator(space) }
        .onChange(of: store.sidebar.reveals) {
          // A split's row goes by its first pane.
          guard let row = space.split(of: space.selectedTabID)?.tabIDs.first ?? space.selectedTabID else { return }
          withAnimation(Motion.layout) { proxy.scrollTo(ListItem.ID.row(row)) }
        }
      }
      .scrollIndicators(.never)
      .zone(.list, $zones)
      .padding(.top, 3)
    }
    .padding(.horizontal, 8)
    // Rows keep their identity wherever they go, so pinning, closing, opening and dropping slide them, and the rows
    // around them, with the row spring.
    .animation(Motion.row, value: items.compactMap(\.rowID))
  }

  private var createPanel: some View {
    SpaceEditor(
      title: "Create a Space", name: "", icon: "", theme: SpaceTheme(),
      profiles: Array(store.spaces.profiles), profile: space.profileID,
      done: { name, icon, theme, profile in
        spaceCreated = true
        store.send(.spaces(.create(name: name, icon: icon, theme: theme, profile: profile)))
        // The fade is picked up on the next pass, once the new space is selected beneath the panel.
        Task { @MainActor in
          isCreatingSpace = false
          freshSpace = store.spaces.selectedID
          try? await Task.sleep(for: .milliseconds(400))
          spaceCreated = false
        }
      },
      cancel: { isCreatingSpace = false },
      createProfile: { store.send(.createProfile(name: $0, spaces: [])) }
    )
    .onPreferenceChange(SpaceIconPreview.self) { iconPreview = $0 }
  }

  private var spaceEditor: some View {
    SpaceEditor(
      title: "Edit Space", name: space.name, icon: space.icon, theme: space.theme, profiles: nil, profile: space.profileID,
      done: { name, icon, theme, _ in
        isEditingSpace = false
        store.send(.spaces(.update(space.id, name: name, icon: icon, theme: theme)))
      },
      cancel: { isEditingSpace = false },
      opening: editorPicker
    )
    .id(space.id)
  }

  private func send(_ action: TabsFeature.Action) {
    store.send(.tab(action, in: space.id))
  }

  private var header: some View {
    let tab = space.selectedTab
    return HStack(spacing: 0) {
      TrafficLights().frame(width: 73, alignment: .leading)
      IconButton(systemName: "sidebar.left") { store.send(.sidebar(.toggle)) }
      Spacer(minLength: 0)
      // Back, forward and reload sit at the right; a narrow sidebar drops reload first, then forward.
      do {
        ViewThatFits(in: .horizontal) {
          navigationButtons(tab, count: 3)
          navigationButtons(tab, count: 2)
          navigationButtons(tab, count: 1)
        }
        .layoutPriority(1)
      }
    }
    // The reload sits 22 pt from the sidebar's edge.
    .padding(.trailing, 5)
    .background {
      // The header's background moves the window, and a double click does what the title bar's would.
      Color.clear.contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .onTapGesture(count: 2) { titleBarDoubleClick() }
    }
    .frame(height: 46)
    .offset(y: 1)
  }

  private func navigationButtons(_ tab: Tab?, count: Int) -> some View {
    HStack(spacing: 0) {
      HistoryButton(direction: .back, tab: tab, space: space, send: send)
      if count > 1 {
        HistoryButton(direction: .forward, tab: tab, space: space, send: send)
      }
      if count > 2 {
        if tab?.isLoading == true {
          IconButton(systemName: "xmark", plate: 34) { send(.stop) }
        } else {
          // ⌘-click duplicates the tab.
          IconButton(systemName: "arrow.clockwise", plate: 34, isEnabled: tab?.isLive == true) {
            guard let tab else { return }
            send(NSApp.currentEvent?.modifierFlags.contains(.command) == true ? .duplicate(tab.id) : .reload)
          }
        }
        if tab?.url.isDeveloperPage == true {
          ReloadMenu()
        }
      }
    }
    .fixedSize()
  }

  // The system's title-bar double click, as set in System Settings: zoom, minimize or nothing.
  private func titleBarDoubleClick() {
    guard let window = NSApp.keyWindow else { return }
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize": window.performMiniaturize(nil)
    case "None": break
    default: window.performZoom(nil)
    }
  }

  private var searchPill: some View {
    let url = space.selectedTab?.url
    return Button { store.send(.editSelectedTab) } label: {
      HStack(spacing: 8) {
        if url == nil {
          Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.pillIcon)
        }
        VStack(alignment: .leading, spacing: 0) {
          Text(url.map { showsFullURL ? $0.absoluteString : $0.domain } ?? "Search...").lineLimit(1)
            .truncationMode(.middle)
          if url != nil, let tab = space.selectedTabID {
            ShareQuoteLabel(tab: tab, accent: Theme.accent(space.theme))
          }
        }
        Spacer()
        if let url {
          PillControls(space: space, url: url, isHovered: isPillHovered, isSidebarHovered: isHovered, copied: { store.send(.showToast("Copied Current URL")) }) {
            send(.open($0))
          }
        }
      }
      .font(.system(size: 13))
      .foregroundStyle(url == nil ? Theme.pillPlaceholder : Theme.pillText)
      // The URL starts 13 pt into the pill, its last icon centered 19 pt from the end.
      .padding(.leading, url == nil ? 12 : 13)
      .padding(.trailing, 11)
      .frame(height: 36)
      .background(
        store.isIncognito ? Theme.incognitoPill : isPillHovered ? Theme.fillHover : Theme.fill,
        in: RoundedRectangle(cornerRadius: 12)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isPillHovered = $0 }
    .onChange(of: store.extensionToRun) { _, id in
      guard let id, let tab = space.selectedTabID else { return }
      commandPopup = Engine.shared.runExtensionAction(id, tab, in: space).map(ExtensionPopup.init)
      store.send(.extensionRan)
    }
    .popover(isPresented: Binding(get: { commandPopup?.isOpen == true }, set: { if !$0 { commandPopup?.close() } }), arrowEdge: .bottom) {
      if let commandPopup {
        WebView(view: commandPopup.popup.view).frame(width: commandPopup.size.width, height: commandPopup.size.height)
      }
    }
    .contextMenu {
      if let url {
        Button(showsFullURL ? "Hide Full URL" : "Show Full URL") { showsFullURL.toggle() }
        Divider()
        Button("Copy URL") {
          copyLink(url)
          store.send(.showToast("Copied Current URL"))
        }
        Button("Take a Capture") { NSApp.sendAction(#selector(WindowController.capture(_:)), to: nil, from: nil) }
        ShareLink("Share Page", item: url)
      }
    }
    .overlay(alignment: .trailing) {
      Color.clear.frame(width: 16, height: 16).padding(.trailing, 11)
        .popover(item: permissionRequest, arrowEdge: .bottom) { PermissionPrompt(request: $0) }
    }
  }

  // The selected tab's permission request; closing the popover answers it "Not Now".
  private var permissionRequest: Binding<PermissionRequest?> {
    let request = space.selectedTabID.flatMap { Engine.shared.permissionRequests[$0] }
    return Binding(get: { request }, set: { if $0 == nil { request?.answer(false) } })
  }

  private func copy(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }

  // Shot 61: a crossed-out eye, brighter than the label, on a faint 22 pt capsule 14 pt from the window edge.
  private var incognitoLabel: some View {
    HStack(spacing: 5) {
      Image(systemName: "eye.slash").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
      Text("Incognito").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.33))
    }
    .padding(.leading, 8)
    .padding(.trailing, 7)
    .frame(height: 22)
    .background(.white.opacity(0.02), in: Capsule())
    .padding(.leading, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func favorites(_ space: Space) -> some View {
    if !space.tabs(in: .favorite).isEmpty {
      // Rows of tiles sharing the width; a placeholder marks where the dragged one will go.
      let rows = favoriteRows(space)
      VStack(spacing: 8) {
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          placeholder(FavoriteSlot(row: index, column: nil))
          HStack(spacing: 8) {
            ForEach(Array(row.enumerated()), id: \.element.id) { column, tab in
              placeholder(FavoriteSlot(row: index, column: column))
              favoriteTile(tab, in: space)
            .landing(isLanding(.tab(tab.id)))
            .pressDown(scale: 0.99) { send(.select(tab.id)) }
            .favoritePreview(tab) { send(.preload(tab.id)) } open: { openPreview($0, of: tab) }
            .contextMenu { tabMenu(tab) }
            .popover(isPresented: isPresented($renamingTab, tab.id), arrowEdge: .bottom) {
              TextField("Name", text: $draftName).textFieldStyle(.roundedBorder).frame(width: 180).padding(10)
                .onSubmit { finishRename(tab) }
            }
            .tabIconPicker(tab.icon, isPresented: isPresented($iconTab, tab.id)) { send(.setIcon(tab.id, $0)) }
            .zone(.tab(tab.id), $zones)
            .transition(.identity)
            }
            placeholder(FavoriteSlot(row: index, column: row.count))
            // A short row keeps the full rows' tile width.
            ForEach(row.count..<(rows.map(\.count).max() ?? row.count), id: \.self) { _ in
              Color.clear.frame(maxWidth: .infinity).frame(height: 47)
            }
          }
        }
        placeholder(FavoriteSlot(row: rows.count, column: nil))
      }
      // The gap below takes a new last row.
      .padding(.bottom, 10)
      .zone(.favorites, $zones)
      .padding(.bottom, -10)
    } else if store.sidebar.showsFavoritesHint || drag != nil {
      VStack(spacing: 3) {
        Image(systemName: "star.circle.fill")
          .symbolRenderingMode(.palette)
          .foregroundStyle(
            Theme.isLight(space.theme) ? .white : Theme.menu,
            Theme.isLight(space.theme) ? Theme.accent(space.theme) : .white
          )
          .font(.system(size: 18))
          .shadow(color: .white.opacity(Theme.isLight(space.theme) ? 0 : 0.35), radius: 4)
          .padding(.bottom, 2)
        Text("Drag to add Favorites").font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Theme.primaryText)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
      // The favorites tile, whose slot this holds: 12.05pt continuous.
      .background(
        drag?.shownTarget?.isFavorite == true ? Theme.fillHover : Theme.favoritesHintFill, in: RoundedRectangle(cornerRadius: 12))
      .background(
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(Theme.favoritesBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      )
      .overlay(alignment: .topTrailing) {
        Button { store.send(.sidebar(.dismissFavoritesHint)) } label: {
          Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.primaryText)
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .padding(5)
      }
      .zone(.favorites, $zones)
    }
  }

  // A preview's item opens in its favorite: at its link, or clicked in the page.
  private func openPreview(_ item: PreviewItem, of tab: Tab) {
    send(.select(tab.id))
    if let url = item.url {
      send(.load(tab.id, url))
    } else {
      FavoritePreviews.shared.click(item, in: tab.id)
    }
  }

  private func favoriteTile(_ tab: Tab, in space: Space) -> some View {
    FavoriteTile(tab: tab, space: space)
      .overlay {
        if keyRow == tab.id {
          RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.primaryText.opacity(0.4), lineWidth: 1.5)
        }
      }
  }

  private func spaceTitle(_ space: Space) -> some View {
    let hasPinned = !space.rows(in: .pinned).isEmpty
    return HStack(spacing: 8) {
      // The chevron shows on hover, and stays while the pinned section is collapsed.
      if hasPinned, isTitleHovered || space.isPinnedCollapsed {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .bold))
          .rotationEffect(.degrees(space.isPinnedCollapsed ? 0 : 90))
          .frame(width: 16, height: 20)
      } else if !space.icon.isEmpty {
        SpaceIcon(icon: space.icon)
      }
      Text(space.name)
      Spacer(minLength: 0)
      if isTitleHovered {
        // The edit button beside the menu opens the space's theme.
        if !store.isIncognito {
          Button { isEditingSpace = true } label: {
            Image(systemName: "paintbrush.pointed").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("Edit Theme")
        }
        Menu { spaceMenu } label: {
          Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).frame(width: 24, height: 24)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
      }
    }
    // Bolds the heading while the pinned section is collapsed.
    .font(.system(size: 13, weight: space.isPinnedCollapsed ? .bold : .semibold))
    .foregroundStyle(Theme.secondaryText)
    .padding(.leading, 8)
    // The … sits 18 pt in from the hover fill's trailing edge.
    .padding(.trailing, 6)
    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    .background(isTitleHovered ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
    .contentShape(Rectangle())
    .onHover { isTitleHovered = $0 }
    // Like a folder's row, the title shows or hides the pinned section; a double click renames the space.
    // Simultaneous, so that a single click toggles at once rather than after the double-click interval.
    .simultaneousGesture(TapGesture(count: 2).onEnded { SpaceMenu.rename(space, store) })
    .onTapGesture {
      guard hasPinned else { return }
      withAnimation(Motion.row) { send(.togglePinnedSection) }
    }
    .contextMenu { spaceMenu }
    .popover(
      isPresented: Binding(
        get: { pickingIconFor == space.id }, set: { if !$0, pickingIconFor == space.id { pickingIconFor = nil } }),
      arrowEdge: .bottom
    ) { IconPicker(icon: $pickedSpaceIcon) }
    .onChange(of: pickedSpaceIcon) { _, icon in
      guard pickingIconFor == space.id, icon != space.icon else { return }
      store.send(.spaces(.update(space.id, name: space.name, icon: icon, theme: space.theme)))
    }
  }

  private var spaceMenu: some View {
    SpaceMenu(
      store: store, space: space,
      changeIcon: {
        pickedSpaceIcon = space.icon
        pickingIconFor = space.id
      },
      editTheme: {
        editorPicker = .theme
        isEditingSpace = true
      },
      newFolder: { newFolder() },
      shareAnchor: { zones.frames[.title] })
  }

  // The menu for the sidebar's empty area: theme, profile and extensions, and the space header.
  @ViewBuilder private var emptySidebarMenu: some View {
    Button("Edit Theme…") { isEditingSpace = true }
      .disabled(store.isIncognito)
    SpaceProfileMenu(title: "Profile", store: store, space: space)
    Button(space.isHeaderHidden ? "Show Space Header" : "Hide Space Header") { send(.toggleHeader) }
      .disabled(store.isIncognito)
    Divider()
    Button("Manage Extensions…") { NSApp.sendAction(#selector(WindowController.showExtensions(_:)), to: nil, from: nil) }
  }

  // The indicator for a selected tab scrolled out of the list; a click scrolls back to it.
  @ViewBuilder private func overflowIndicator(_ space: Space) -> some View {
    if space.id == store.spaces.selectedID, let edge = selectedOffscreen, let tab = space.selectedTab {
      Button { store.send(.sidebar(.reveal)) } label: {
        HStack(spacing: 6) {
          Image(systemName: edge == .top ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
          TabFavicon(tab: tab, space: space).frame(width: 16, height: 16)
        }
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Theme.selection, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
      }
      .buttonStyle(.plain)
      .padding(edge == .top ? .top : .bottom, 4)
    }
  }

  // A swipe far enough toward a neighbor lands there on release even if the fingers lift still.
  private var swipeLands: Bool {
    overscroll == 0 && abs(stripSwipe) > store.sidebar.visibleWidth * commitDistance / 100
  }

  // Asks before emptying the archive, then confirms with a toast.
  private func clearArchive() {
    guard let window = NSApp.keyWindow else { return }
    presentModal(over: window) { dismiss in
      ClearArchiveDialog(clear: { store.send(.clearArchive) }, dismiss: dismiss)
    }
  }

  // The pinned section, the divider, New Tab and Today as one list, folders' rows at their depth.
  private func listItems(_ space: Space) -> [ListItem] {
    var items: [ListItem] = []
    func gap(_ target: DropTarget, depth: Int) {
      let isDropSlot = isDropTargeted && target == .slot(.unpinned, before: space.tabs(in: .unpinned).first?.id)
      if drag?.isLanding == false && drag?.shownTarget == target || isDropSlot {
        items.append(.gap(target, depth: depth))
      }
    }
    // A split shows once, as one row of its tabs, where its first pane is.
    func tab(_ tab: Tab, depth: Int, isFolded: Bool = false) {
      if space.split(of: tab.id).map({ $0.tabIDs[0] == tab.id }) ?? true {
        items.append(.tab(tab, depth: depth, isFolded: isFolded))
      }
    }
    // A collapsed pinned section or folder folds its rows up under it, all but the selected tab.
    func rows(_ container: Placement, depth: Int, isFolded: Bool) {
      for row in space.rows(in: container) {
        gap(.slot(container, before: row.id), depth: depth)
        switch row {
        case let .tab(item):
          let isSelected = space.split(of: item.id)?.tabIDs.contains { $0 == space.selectedTabID } ?? (item.id == space.selectedTabID)
          tab(item, depth: depth, isFolded: isFolded && !isSelected)
        case let .folder(folder):
          items.append(.folder(folder, depth: depth, isFolded: isFolded))
          rows(.folder(folder.id), depth: depth + 1, isFolded: isFolded || !folder.isOpen)
        }
      }
      gap(.slot(container, before: nil), depth: depth)
    }
    rows(.pinned, depth: 0, isFolded: space.isPinnedCollapsed)
    items += [.divider, .newTab]
    // A tab group shows where its first tab is, its tabs indented under its header.
    var listed: Set<TabGroup.ID> = []
    for item in space.tabs(in: .unpinned) {
      guard let group = item.groupID.flatMap({ space.groups[id: $0] }) else {
        gap(.slot(.unpinned, before: item.id), depth: 0)
        tab(item, depth: 0)
        continue
      }
      guard listed.insert(group.id).inserted else { continue }
      gap(.slot(.unpinned, before: item.id), depth: 0)
      items.append(.group(group))
      for member in space.members(of: group.id) {
        gap(.grouped(group.id, before: member.id), depth: 1)
        tab(member, depth: 1, isFolded: space.isFoldedInGroup(member))
      }
      gap(.grouped(group.id, before: nil), depth: 1)
    }
    gap(.slot(.unpinned, before: nil), depth: 0)
    return items
  }

  @ViewBuilder private func listItem(_ item: ListItem, in space: Space) -> some View {
    switch item {
    case let .tab(tab, depth, isFolded):
      let isShown = space.id == store.spaces.selectedID
        && space.split(of: tab.id)?.tabIDs.contains { $0 == space.selectedTabID } ?? (tab.id == space.selectedTabID)
      tabRow(tab, in: space)
        .background(keyRow == tab.id ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
        // Which edge of the list the selected row is scrolled past, if it is. Naming the row makes a newly
        // selected row report even when it is in view.
        .onGeometryChange(for: ShownRowEdge?.self) { proxy in
          guard isShown else { return nil }
          let frame = proxy.frame(in: .scrollView)
          return ShownRowEdge(tab: tab.id, edge: frame.midY < 0 ? .top : frame.midY > listHeight ? .bottom : nil)
        } action: { shown in
          if let shown { selectedOffscreen = shown.edge }
        }
        // A group's tabs have its color down their left.
        .overlay(alignment: .leading) {
          if depth > 0, let group = tab.groupID.flatMap({ space.groups[id: $0] }) {
            Capsule().fill(group.color.swatch).frame(width: 3).padding(.vertical, 9).offset(x: -9)
          }
        }
        .folded(isFolded)
        .padding(.leading, CGFloat(depth) * 16)
        // A closed row goes in one frame and the rows below close up; only a just opened or restored
        // one fades in.
        .transition(.asymmetric(insertion: space.arrivals.contains(tab.id) ? .opacity : .identity, removal: .identity))
        // The row moves as one piece, so a subtitle a pin adds travels with it rather than appearing in the new slot.
        .geometryGroup()
        // The selected row passes over the others when a pin or unpin moves it.
        .zIndex(tab.id == space.selectedTabID ? 1 : 0)
    case let .folder(folder, depth, isFolded):
      folderItem(folder, in: space)
        .folded(isFolded)
        .padding(.leading, CGFloat(depth) * 16)
        .transition(.asymmetric(insertion: .identity, removal: .opacity))
        .geometryGroup()
    case let .group(group):
      groupItem(group, in: space)
        .background(keyRow == group.id ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
        .transition(.asymmetric(insertion: .identity, removal: .opacity))
        .geometryGroup()
    case let .gap(_, depth):
      // The line snaps between boundaries and leaves at once on drop.
      insertionLine.zone(.line, $zones).padding(.leading, CGFloat(depth) * 16)
        .transition(.identity)
        .zIndex(2)
    case .divider:
      divider(space)
    case .newTab:
      // Lights the row while the command bar is open for a new tab (white at 19% over a dark theme), and pulses
      // its label in a space just created until its first tab.
      let isLit = store.commandBar.map { $0.editing == nil } ?? false
      SidebarRow(isSelected: isLit) {
        Image(systemName: "plus").font(.system(size: 14, weight: .medium))
        Text("New Tab")
      }
      .foregroundStyle(isLit ? Theme.rowText : Theme.secondaryText)
      .pulsing(space.id == freshSpace && space.ownTabs.isEmpty && !isLit)
      .onTapGesture { store.send(.showCommandBar) }
      .padding(.vertical, Self.rowGap)
      .zone(.newTab, $zones)
      .geometryGroup()
    }
  }

  private func divider(_ space: Space) -> some View {
    let today = space.tabs(in: .unpinned)
    // Shows the divider only while Today has tabs, pinned rows or not.
    let showsDivider = !today.isEmpty
    return HStack(spacing: 8) {
      // One device pixel on any display.
      TidyDividerLine(isTidying: space.isTidying, color: showsDivider ? Theme.divider : .clear, lineWidth: 1 / displayScale)
      // Shows Clear only while the pointer is over the sidebar, and only while it has something to archive, and
      // Tidy before it once Today has several tabs to sort.
      if !today.isEmpty, isHovered {
        if space.isTidying || space.tidyCandidates.count >= TabsFeature.tidyMinimum {
          TidyButton(isTidying: space.isTidying, isHovered: $isTidyHovered) { send(.tidy(.start)) }
          Rectangle().fill(Theme.divider).frame(width: 1, height: 12)
        }
        Button { send(.clearToday) } label: {
          // The label is 26.5 pt wide and 8 pt tall at cap height: 10 pt semibold.
          Text(isClearHovered ? "↓ Clear" : "Clear").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.clearLabel)
            .opacity(isTidyHovered ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isClearHovered = $0 }
        .transition(.opacity)
      }
    }
    .animation(Motion.layout, value: isHovered)
    .padding(.horizontal, 10)
    // The divider is 29 pt below the title's center and 28.75 pt above New Tab's.
    .frame(height: showsDivider ? 16 : 0)
    .contentShape(Rectangle())
    .zone(.pinnedEnd, $zones)
  }

  private func folderItem(_ folder: Folder, in space: Space) -> some View {
    folderRow(folder, in: space)
      .landing(isLanding(.folder(folder.id)))
      // Simultaneous, as on the space title: a click folds at once, a double click renames.
      .simultaneousGesture(TapGesture(count: 2).onEnded { rename(folder) })
      .onTapGesture { withAnimation(Motion.row) { send(.toggleFolder(folder.id)) } }
      .contextMenu { folderMenu(folder) }
      .onHover { hoveredFolder = $0 ? folder.id : hoveredFolder == folder.id ? nil : hoveredFolder }
      .popover(isPresented: isPresented($peekFolder, folder.id), arrowEdge: .trailing) {
        FolderSearch(folder: folder, tabs: folderTabs(folder.id, in: space)) {
          peekFolder = nil
          send(.select($0))
        }
        .onHover { isPeekHovered = $0 }
      }
      .tabIconPicker(folder.icon, isPresented: isPresented($iconTab, folder.id)) { send(.setFolderIcon(folder.id, $0)) }
      .zone(.folder(folder.id), $zones)
  }

  // Order: New Nested Folder, Turn into Space, Copy All Links | Change Icon, Rename | Duplicate, Move to |
  // Delete.
  @ViewBuilder private func folderMenu(_ folder: Folder) -> some View {
    Button("New Nested Folder…") { newFolder(in: .folder(folder.id)) }
    Button("Turn “\(folder.name)” into Space") { store.send(.spaces(.folderToSpace(folder.id, in: space.id))) }
      .disabled(store.isIncognito)
    if !folderTabs(folder.id, in: space).isEmpty {
      Button("Copy All Links") { copyLinks(of: folder, markdown: false) }
        .modifierKeyAlternate(.option) {
          Button("Copy All Links as Markdown") { copyLinks(of: folder, markdown: true) }
        }
    }
    Divider()
    Button("Change Icon…") { iconTab = folder.id }
    Button("Rename…") { rename(folder) }
    Divider()
    Button("Duplicate") { send(.duplicateFolder(folder.id)) }
    Menu("Move to") {
      ForEach(store.isIncognito ? [] : store.spaces.spaces.filter { $0.id != space.id }) { item in
        Button(item.name) { store.send(.spaces(.moveFolder(folder.id, from: space.id, to: item.id))) }
      }
    }
    Divider()
    Button("Delete") { send(.deleteFolder(folder.id)) }
  }

  // A tab group's header: its color, its name, and while closed how many tabs it holds.
  private func groupItem(_ group: TabGroup, in space: Space) -> some View {
    let count = space.members(of: group.id).count
    return SidebarRow(isSelected: false) {
      RoundedRectangle(cornerRadius: 3).fill(group.color.swatch).frame(width: 12, height: 12).frame(width: 20)
        .padding(.horizontal, -2)
      if renamingGroup == group.id {
        TextField("Group name", text: $draftName)
          .textFieldStyle(.plain)
          .focused($isNameFocused)
          .onAppear {
            isNameFocused = true
            DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil) }
          }
          .onSubmit {
            send(.renameGroup(group.id, draftName))
            renamingGroup = nil
          }
          .onExitCommand { renamingGroup = nil }
      } else {
        Text(group.name).fontWeight(.semibold)
        Spacer(minLength: 0)
        // Hover buttons on a Tidy header: its tabs into a pinned folder, and closing them.
        if hoveredGroup == group.id, drag == nil {
          groupButton("folder", "Turn into Folder") {
            withAnimation(Motion.row) { send(.newFolder(group.name, in: .pinned, with: space.members(of: group.id).map(\.id))) }
          }
          groupButton("xmark", "Close Group") { send(.closeGroup(group.id)) }
        }
        if !group.isOpen {
          Text("\(count)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
        }
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.icon)
          .rotationEffect(.degrees(group.isOpen ? 90 : 0))
      }
    }
    .padding(.vertical, Self.rowGap)
    .onHover { hoveredGroup = $0 ? group.id : hoveredGroup == group.id ? nil : hoveredGroup }
    .simultaneousGesture(TapGesture(count: 2).onEnded { rename(group) })
    .onTapGesture { withAnimation(Motion.row) { send(.toggleGroup(group.id)) } }
    .contextMenu { groupMenu(group) }
    .accessibilityElement(children: renamingGroup == group.id ? .contain : .ignore)
    .accessibilityLabel("\(group.name), \(group.color.name) tab group, \(count == 1 ? "1 tab" : "\(count) tabs")")
    .accessibilityValue(group.isOpen ? "Expanded" : "Collapsed")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { withAnimation(Motion.row) { send(.toggleGroup(group.id)) } }
    .accessibilityAction(named: "Rename") { rename(group) }
    .accessibilityAction(named: "Remove Header") { withAnimation(Motion.row) { send(.ungroup(group.id)) } }
    .accessibilityAction(named: "Close Group") { send(.closeGroup(group.id)) }
    .zone(.group(group.id), $zones)
  }

  private func groupButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.icon)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverTooltip(title)
  }

  @ViewBuilder private func groupMenu(_ group: TabGroup) -> some View {
    Button("Rename…") { rename(group) }
    Menu("Color") {
      ForEach(TabGroup.Color.allCases, id: \.self) { color in
        Toggle(color.name, isOn: Binding { group.color == color } set: { _ in send(.setGroupColor(group.id, color)) })
      }
    }
    Divider()
    Button(group.isOpen ? "Collapse Group" : "Expand Group") { withAnimation(Motion.row) { send(.toggleGroup(group.id)) } }
    // Remove Header: the tabs stay where they are.
    Button("Remove Header") { withAnimation(Motion.row) { send(.ungroup(group.id)) } }
    Divider()
    Button("Close Group") { send(.closeGroup(group.id)) }
  }

  // Add to New Group, Add to Group ▸ and Remove from Group, for Today tabs.
  @ViewBuilder private func groupItems(_ tabs: [Tab]) -> some View {
    let ids = tabs.map(\.id)
    let current = Set(tabs.map(\.groupID))
    Button("Add to New Group") { newGroup(with: ids) }
    let others = space.groups.filter { current != [$0.id] }
    if !others.isEmpty {
      Menu("Add to Group") {
        ForEach(others) { group in
          Button(group.name) { withAnimation(Motion.row) { send(.group(ids, into: group.id)) } }
        }
      }
    }
    if current != [nil] {
      Button("Remove from Group") { withAnimation(Motion.row) { send(.removeFromGroup(ids)) } }
    }
  }

  private func newGroup(with ids: [Tab.ID]) {
    withAnimation(Motion.row) { send(.newGroup(with: ids)) }
    guard let group = space.groups.last else { return }
    rename(group)
  }

  private func rename(_ group: TabGroup) {
    draftName = group.name
    renamingGroup = group.id
  }

  // Shows a collapsed folder's tabs after the pointer rests on it, and hides them once it has left both.
  private func peek() async {
    try? await Task.sleep(for: .seconds(0.4))
    guard !Task.isCancelled else { return }
    if let id = hoveredFolder, space.folders[id: id]?.isOpen == false, !folderTabs(id, in: space).isEmpty, drag == nil {
      peekFolder = id
    } else if hoveredFolder == nil, !isPeekHovered, menuFolder == nil {
      peekFolder = nil
    }
  }

  // Every link in the folder, nested folders included, one per line, plain or as Markdown links.
  private func copyLinks(of folder: Folder, markdown: Bool) {
    let lines = folderTabs(folder.id, in: space).map { tab in
      guard markdown else { return tab.url.absoluteString }
      let title = tab.displayTitle.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
      return "[\(title)](\(tab.url.absoluteString.replacingOccurrences(of: ")", with: "%29")))"
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    store.send(.showToast("Copied item links"))
  }

  // The folder's tabs, nested ones included.
  private func folderTabs(_ id: Folder.ID, in space: Space) -> [Tab] {
    space.tree(.folder(id)).compactMap { if case let .tab(tab) = $0 { tab } else { nil } }
  }

  private func folderRow(_ folder: Folder, in space: Space) -> some View {
    SidebarRow(isSelected: false) {
      Group {
        if let icon = folder.icon {
          SpaceIcon(icon: icon, emojiSize: 15)
        } else {
          FolderGlyph(isOpen: folder.isOpen, accent: Theme.accent(space.theme))
        }
      }
      // Swaps the open and closed glyphs in one frame while the rows fold.
      .animation(nil, value: folder.isOpen)
      .frame(width: 20)
      .padding(.horizontal, -2)
      if renamingFolder == folder.id {
        // The rename field keeps the folder name's weight.
        TextField("Folder name", text: $draftName)
          .textFieldStyle(.plain)
          .fontWeight(.semibold)
          .focused($isNameFocused)
          .onAppear {
            isNameFocused = true
            // The name is selected, so typing replaces "Untitled".
            DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil) }
          }
          .onSubmit {
            send(.renameFolder(folder.id, draftName))
            renamingFolder = nil
            newFolderID = nil
          }
          .onExitCommand {
            // Its creation is the last undo entry unless something happened since; then only an empty folder goes.
            if newFolderID == folder.id {
              if case let .createFolder(_, id, _)? = store.undoStack.last, id == folder.id {
                store.send(.undo, animation: Motion.row)
              } else if space.tree(.folder(folder.id)).isEmpty {
                withAnimation(Motion.row) { send(.deleteFolder(folder.id)) }
              }
            }
            renamingFolder = nil
            newFolderID = nil
          }
      } else {
        Text(folder.name).fontWeight(.semibold)
        // The hover "−" unloads the folder's open tabs.
        let live = folderTabs(folder.id, in: space).filter(\.isLive)
        if hoveredFolder == folder.id, drag == nil, !live.isEmpty {
          Spacer(minLength: 0)
          // The folder "−" is an 11.5 x 2 pt bar, 17 pt from the row's end.
          Button { for tab in live { send(.close(tab.id)) } } label: {
            Rectangle().fill(Theme.icon).frame(width: 11.5, height: 2)
              .frame(width: 22, height: 22)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .onHover { isFolderMinusHovered = $0 }
          .padding(.trailing, -3.5)
        }
      }
    }
    .padding(.vertical, Self.rowGap)
  }

  // Sidebar drag: a copy follows the pointer and a line marks where the row will land.
  private func dragChanged(_ value: DragGesture.Value) {
    if drag?.isLanding == true || drag?.drop != nil || dragDot(value) { return }
    if drag == nil {
      guard let (zone, frame) = zone(at: value.startLocation) else { return }
      switch zone {
      case let .tab(id):
        guard let tab = space.tabs[id: id] else { return }
        let target = tab.placement == .favorite ? .favorite(slot(of: id)) : slot(below: tab)
        drag = Drag(item: .tab(id), space: space.id, frame: frame, grab: grab(value.startLocation, in: frame), target: target)
        // A drag moves one row; the multi-selection ends.
        if !space.selection.isEmpty { send(.clearSelection) }
      case let .folder(id) where renamingFolder != id:
        guard let folder = space.folders[id: id] else { return }
        drag = Drag(
          item: .folder(id), space: space.id, frame: frame, grab: grab(value.startLocation, in: frame),
          target: .slot(folder.placement, before: next(id, in: folder.placement)))
      default:
        return
      }
    }
    drag?.location = value.location
    // Over the page or anywhere else that takes no drop, the line and highlights go until the pointer is back.
    let target = target(at: value.location)
    if let drag, (target == nil) != drag.isOutside {
      withAnimation(drag.target.isFavorite ? Motion.layout : nil) { self.drag?.isOutside = target == nil }
    }
    guard let target, target != drag?.target else { return }
    // Ticks the trackpad on each change of target, with the strong pattern.
    tick()
    // The Favorites grid reflows around the placeholder; list rows hold still under the line.
    withAnimation(drag?.target.isFavorite == true || target.isFavorite ? Motion.layout : nil) { drag?.target = target }
  }

  // The trackpad tick during a tab drag, unless Settings > Advanced turns it off; it lands with the frame that
  // draws the change.
  private func tick() {
    guard tabReorderingHaptics else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .drawCompleted)
  }

  // Where in the row the pointer picked it up, as fractions of its size, so the copy keeps that point under the
  // pointer whatever its size.
  private func grab(_ point: CGPoint, in frame: CGRect) -> CGPoint {
    CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
  }

  private func target(at point: CGPoint) -> DropTarget? {
    guard let drag, let (zone, frame) = zone(at: point) else { return nil }
    let isTab = if case .tab = drag.item { true } else { false }
    switch zone {
    case let .tab(other):
      guard let tab = space.tabs[id: other], isTab || tab.placement.isPinnedSection else { return nil }
      if tab.placement == .favorite { return favoriteTarget(at: point) }
      // Offers a split on all of another tab's row but its edges, the dragged tab on the pointer's side; the
      // line between rows shows only within a few points of their boundary.
      if isTab, other != drag.item.id, space.split(of: drag.item.id) == nil,
        abs(point.y - frame.midY) < frame.height / 2 - Self.lineBand
      {
        let panes = space.split(of: other)?.tabIDs.count ?? 1
        guard panes < Space.maxPanes else { return nil }
        return .split(beside: other, at: Int(((point.x - frame.minX) / frame.width * CGFloat(panes)).rounded()))
      }
      return point.y > frame.midY ? slot(below: tab) : slot(above: tab)
    case let .group(id) where isTab:
      // A group's header: its top half places above the group, its bottom half at the top of it (the end, closed).
      guard let group = space.groups[id: id], let first = space.members(of: id).first else { return nil }
      return point.y < frame.midY ? .slot(.unpinned, before: first.id) : .grouped(id, before: group.isOpen ? first.id : nil)
    case let .folder(other):
      // A row's top and bottom place beside it; its middle drops into it.
      guard let folder = space.folders[id: other] else { return nil }
      if point.y < frame.minY + frame.height * 0.25 { return .slot(folder.placement, before: other) }
      if point.y > frame.maxY - frame.height * 0.25 { return .slot(folder.placement, before: next(other, in: folder.placement)) }
      return other == drag.item.id ? nil : .into(other)
    case .title:
      return .slot(.pinned, before: space.rows(in: .pinned).first?.id)
    // The hint stands in for the empty pinned section, so a row dropped on it is pinned.
    case .pinnedEnd, .pinnedHint:
      return .slot(.pinned, before: nil)
    case .newTab where isTab:
      return .slot(.unpinned, before: space.tabs(in: .unpinned).first?.id)
    case .list where isTab:
      return .slot(.unpinned, before: nil)
    case .favorites where isTab:
      return favoriteTarget(at: point)
    case .placeholder:
      // The placeholder is drawn only for the current target, so resting on it keeps that target.
      return drag.target
    case let .dot(id) where isTab:
      return id == space.id ? nil : .space(id)
    default:
      return nil
    }
  }

  // Spaces reorder by dragging their dots: the others slide aside, and the order is kept on release.
  private func dragDot(_ value: DragGesture.Value) -> Bool {
    if dotDrag == nil {
      guard drag == nil, !isCreatingSpace, case let (.dot(id), _)? = zone(at: value.startLocation) else { return false }
      dotDrag = DotDrag(id: id, order: store.spaces.spaces.ids.elements)
    }
    guard var dotDrag else { return false }
    dotDrag.x = value.location.x
    let others = dotDrag.order.filter { $0 != dotDrag.id }
    let index = others.count { zones.frames[.dot($0)].map { $0.midX < value.location.x } ?? false }
    let moves = dotDrag.order.firstIndex(of: dotDrag.id) != index
    dotDrag.order = others
    dotDrag.order.insert(dotDrag.id, at: index)
    withAnimation(moves ? Motion.layout : nil) { self.dotDrag = dotDrag }
    return true
  }

  private func drop(at location: CGPoint) {
    if let dotDrag {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        self.dotDrag = nil
        store.send(.spaces(.moveSpace(dotDrag.id, to: dotDrag.order.firstIndex(of: dotDrag.id)!)))
      }
      return
    }
    guard let drag, !drag.isLanding, drag.drop == nil else { return }
    // Released where nothing takes it, the copy flies back to its row and nothing moves.
    if target(at: location) == nil {
      withAnimation(Motion.land, completionCriteria: .removed) {
        // A dragged favorite has left the grid, so it goes back to where it was lifted.
        self.drag?.landing = (zones.frames[drag.item.zone] ?? drag.frame).origin
      } completion: {
        if self.drag?.isLanding == true {
          self.drag = nil
        }
      }
      return
    }
    tick()
    let copies = NSEvent.modifierFlags.contains(.option)
    if case let (.tab(id), .space(to)) = (drag.item, drag.target) {
      self.drag = nil
      store.send(.spaces(copies ? .copyTab(id, from: drag.space, to: to) : .moveTab(id, from: drag.space, to: to)))
      return
    }
    // A tab carried to another space by its dot lands in that space's list: with ⌥ held a copy lands at its top,
    // otherwise it moves in the split as it forms, or else now.
    let carried = drag.space != space.id
    if case let .tab(id) = drag.item, carried, copies {
      self.drag = nil
      let target = copyTarget(drag.target)
      store.send(.spaces(.copyTab(id, from: drag.space, to: space.id, placement: target?.0, before: target?.1)))
      return
    }
    if case let (.tab(id), .split(other, index)) = (drag.item, drag.target) {
      // Drops the copy at once, flashes the split half solid, shows the row plain for a moment, then crossfades
      // the list into the new split.
      self.drag?.drop = .flashing
      Task {
        try? await Task.sleep(for: Motion.splitFlash)
        self.drag?.drop = .paused
        try? await Task.sleep(for: Motion.splitPause)
        withAnimation(Motion.fade) {
          if carried { store.send(.spaces(.moveTab(id, from: drag.space, to: space.id))) }
          send(.split(id, beside: other, at: index))
        }
        self.drag = nil
      }
      return
    }
    if case let .tab(id) = drag.item, carried {
      store.send(.spaces(.moveTab(id, from: drag.space, to: space.id)))
    }
    // Dropped with ⌥ held, the row stays and a copy of the tab arrives where the line is.
    if copies, case let .tab(id) = drag.item, let (placement, before) = copyTarget(drag.target) {
      self.drag = nil
      withAnimation(Motion.row) { send(.duplicate(id, to: placement, before: before)) }
      return
    }
    // The drop is marked first, with no animation: the copy turns opaque and the list takes the row motion for the
    // rows closing up and making room. The rows move, and last the copy alone eases into its slot.
    let landing = landing(drag)
    var dropped = Transaction()
    dropped.disablesAnimations = true
    withTransaction(dropped) {
      self.drag?.isDropped = true
      // The placeholder leaves the grid as the landing starts, so the tile's size is kept from here.
      if drag.target.isFavorite { self.drag?.landingSize = zones.frames[.placeholder]?.size }
    }
    withAnimation(nil) {
      switch (drag.item, drag.target) {
      case let (.tab(id), .slot(placement, before)):
        send(.move(id, placement, before: before))
      case let (.tab(id), .favorite(slot)):
        send(.moveFavorite(id, to: slot))
      case let (.tab(id), .grouped(group, before)):
        send(.group([id], into: group, before: before))
      case let (.tab(id), .into(folder)):
        send(.move(id, .folder(folder), before: firstRow(in: folder)))
        send(.select(id))
      case let (.folder(id), .slot(placement, before)):
        send(.moveFolder(id, placement, before: before))
      case let (.folder(id), .into(folder)):
        send(.moveFolder(id, .folder(folder), before: firstRow(in: folder)))
      default:
        break
      }
    }
    guard let landing else {
      self.drag = nil
      return
    }
    withAnimation(Motion.land, completionCriteria: .logicallyComplete) {
      self.drag?.landing = landing
    } completion: {
      if self.drag?.isLanding == true {
        self.drag = nil
      }
    }
  }

  // Where an ⌥-drop's copy goes: the slot the line marks, or the folder's first row.
  private func copyTarget(_ target: DropTarget) -> (Placement, UUID?)? {
    switch target {
    case let .slot(placement, before): (placement, before)
    case let .into(folder): (.folder(folder), firstRow(in: folder))
    case let .grouped(_, before): (.unpinned, before)
    case .favorite, .split, .space: nil
    }
  }

  // Where the dropped row settles, worked out before the move so that its copy heads straight there: the slot the
  // line marks, the folder's first row, or the Favorites placeholder. A row leaving from above the slot takes its
  // height with it.
  private func landing(_ drag: Drag) -> CGPoint? {
    let slot: CGPoint
    switch drag.target {
    case .slot, .grouped:
      guard let line = zones.frames[.line] else { return nil }
      slot = line.origin
    case let .into(folder):
      guard let frame = zones.frames[.folder(folder)] else { return nil }
      slot = CGPoint(x: frame.minX + 16, y: frame.maxY)
    case .favorite:
      return zones.frames[.placeholder]?.origin
    case .split, .space:
      return nil
    }
    // A favorite has already left the grid, and a row from another space was never in this list. The row's frame
    // is read now, not at the drag's start, so a scroll during the drag is accounted for.
    guard drag.space == space.id, dragged(drag)?.placement != .favorite, let source = zones.frames[drag.item.zone],
      source.minY < slot.y
    else { return slot }
    return CGPoint(x: slot.x, y: slot.y - height(of: drag.item, at: source))
  }

  // The dragged row's height, with a folder's visible rows.
  private func height(of item: DragItem, at source: CGRect) -> CGFloat {
    guard case let .folder(id) = item else { return source.height }
    let rows = space.tree(.folder(id)).compactMap { row -> CGRect? in
      switch row {
      case let .tab(tab): zones.frames[.tab(tab.id)]
      case let .folder(folder): zones.frames[.folder(folder.id)]
      }
    }
    return (rows.map(\.maxY).max() ?? source.maxY) - source.minY
  }

  // Files a row dropped on an open folder at its top, and on a closed one at its end.
  private func firstRow(in folder: Folder.ID) -> UUID? {
    space.folders[id: folder]?.isOpen == true ? space.rows(in: .folder(folder)).first?.id : nil
  }

  // The innermost zone under the point.
  private func zone(at point: CGPoint) -> (Zone, CGRect)? {
    zones.frames.filter { $0.value.contains(point) }.min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }
      .map { ($0.key, $0.value) }
  }

  // The row after this one in its placement.
  private func next(_ id: UUID, in placement: Placement) -> UUID? {
    let ids = placement.isPinnedSection ? space.rows(in: placement).map(\.id) : space.tabs(in: placement).map(\.id)
    return ids.firstIndex(of: id).flatMap { $0 + 1 < ids.count ? ids[$0 + 1] : nil }
  }

  // The slots above and below a tab's row: in its group, or in its placement. Below a group's last tab is its end.
  private func slot(above tab: Tab) -> DropTarget {
    guard let group = tab.groupID, space.groups[id: group] != nil else { return .slot(tab.placement, before: tab.id) }
    return .grouped(group, before: tab.id)
  }

  private func slot(below tab: Tab) -> DropTarget {
    guard let group = tab.groupID, space.groups[id: group] != nil else {
      return .slot(tab.placement, before: next(tab.id, in: tab.placement))
    }
    let members = space.members(of: group).map(\.id)
    let index = members.firstIndex(of: tab.id)!
    return .grouped(group, before: index + 1 < members.count ? members[index + 1] : nil)
  }

  // The favorites' rows; a dragged favorite leaves them, and they reflow around the placeholder.
  private func favoriteRows(_ space: Space) -> [[Tab]] {
    space.favoriteGrid.map { $0.filter { drag?.isLanding != false || drag?.item != .tab($0.id) } }.filter { !$0.isEmpty }
  }

  // A favorite's own place, among the rows left without it.
  private func slot(of id: Tab.ID) -> FavoriteSlot {
    let grid = space.favoriteGrid
    let row = grid.firstIndex { $0.contains { $0.id == id } }!
    let column = grid[row].firstIndex { $0.id == id }!
    return grid[row].count == 1 ? FavoriteSlot(row: row, column: nil) : FavoriteSlot(row: row, column: column)
  }

  // A row's top and bottom quarters, and the gaps, make a new row; its middle goes between its tiles.
  private func favoriteTarget(at point: CGPoint) -> DropTarget? {
    let rows = favoriteRows(space)
    for (index, row) in rows.enumerated() {
      guard let frame = row.compactMap({ zones.frames[.tab($0.id)] }).reduce(nil, { $0?.union($1) ?? $1 }) else { continue }
      if point.y < frame.minY + frame.height / 4 { return .favorite(FavoriteSlot(row: index, column: nil)) }
      if point.y <= frame.maxY - frame.height / 4 {
        guard row.count < Space.favoritesPerRow else { return nil }
        let column = row.filter { zones.frames[.tab($0.id)].map { $0.midX < point.x } ?? false }.count
        return .favorite(FavoriteSlot(row: index, column: column))
      }
    }
    return .favorite(FavoriteSlot(row: rows.count, column: nil))
  }

  // The dropped row hides while its copy settles into its slot.
  private func isLanding(_ item: DragItem) -> Bool {
    drag?.isLanding == true && drag?.item == item
  }

  // The insertion line: 2 pt of white with a small ring at its left end.
  private var insertionLine: some View {
    Color.clear.frame(height: 0)
      .overlay(alignment: .leading) {
        HStack(spacing: 0) {
          Circle().strokeBorder(.white, lineWidth: 1.5).frame(width: 6, height: 6)
          Rectangle().fill(.white).frame(height: 2)
        }
        .padding(.leading, 9)
        .padding(.trailing, 2)
      }
  }

  // The Favorites placeholder: the dragged favicon on a light tile with a white outline.
  @ViewBuilder private func placeholder(_ slot: FavoriteSlot) -> some View {
    if let drag, !drag.isLanding, drag.shownTarget == .favorite(slot), let tab = dragged(drag) {
      TabFavicon(tab: tab, space: space)
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.8), lineWidth: 2))
        .zone(.placeholder, $zones)
        .transition(.identity)
    }
  }

  // The dragged tab, looked up in the space it came from.
  private func dragged(_ drag: Drag) -> Tab? {
    guard case let .tab(id) = drag.item else { return nil }
    return store.spaces.spaces[id: drag.space]?.tabs[id: id]
  }

  @ViewBuilder private func draggedRow(_ drag: Drag, asTile: Bool) -> some View {
    switch drag.item {
    case .tab:
      if let tab = dragged(drag) {
        if tab.placement == .favorite || asTile {
          favoriteTile(tab, in: space)
        } else {
          TabRow(
            tab: tab, space: space, isSelected: tab.id == space.selectedTabID, name: nil, endRename: { _ in },
            backToPinnedURL: {}, isLifted: true
          ) {}
          .padding(.vertical, Self.rowGap)
        }
      }
    case let .folder(id):
      if let folder = space.folders[id: id] {
        folderRow(folder, in: space).background(Theme.selection, in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private func newFolder(in container: Placement = .pinned, with tabs: [Tab.ID] = []) {
    withAnimation(tabs.isEmpty ? nil : Motion.row) { send(.newFolder(in: container, with: tabs)) }
    guard let folder = space.folders.last else { return }
    newFolderID = folder.id
    rename(folder)
  }

  private func rename(_ folder: Folder) {
    draftName = folder.name
    renamingFolder = folder.id
  }

  private func tabRow(_ tab: Tab, in space: Space) -> some View {
    let panes = space.split(of: tab.id).map { $0.tabIDs.compactMap { space.tabs[id: $0] } }
    let hover = splitHover(on: tab.id, in: space)
    return Group {
      if let panes {
        SplitRow(tabs: panes, space: space, act: { send($0) }) { tabMenu($0) }
          .splitHalf(hover)
          .padding(.vertical, Self.rowGap)
          .zone(.tab(tab.id), $zones)
      } else {
        plainTabRow(tab, in: space, splitHover: hover)
      }
    }
  }

  // The dragged tab resting on this row's middle, and how far along the split affordance it is.
  private func splitHover(on tab: Tab.ID, in space: Space) -> SplitHover? {
    guard let drag, case let .split(other, index)? = drag.shownTarget, other == tab else { return nil }
    let phase: SplitHover.Phase = drag.drop == .flashing ? .flashing : splitArmed == drag.shownTarget ? .armed : .pending
    return SplitHover(index: index, count: (space.split(of: other)?.tabIDs.count ?? 1) + 1, phase: phase)
  }

  private func plainTabRow(_ tab: Tab, in space: Space, splitHover: SplitHover?) -> some View {
    // An unloaded pinned tab's X removes it; otherwise the button closes it.
    TabRow(
      tab: tab, space: space, isSelected: tab.id == space.selectedTabID || space.selection.contains(tab.id),
      name: renamingTab == tab.id ? $draftName : nil,
      endRename: { if $0 { finishRename(tab) } else { renamingTab = nil } },
      // ⌘-click keeps the page it moved on to, in a new Today tab.
      backToPinnedURL: {
        send(NSEvent.modifierFlags.contains(.command) ? .separateFromPinned(tab.id) : .resetToPinnedURL(tab.id))
      },
      // The dragged row stays in place, lifted.
      isLifted: drag?.item == .tab(tab.id),
      splitHover: splitHover,
      toggleMute: { send(.toggleMute(tab.id)) }
    ) {
      send(tab.pinnedURL != nil && !tab.isLive ? .archive([tab.id]) : .close(tab.id))
    }
      .splitHalf(splitHover)
      // ⌘-click and ⇧-click gather a multi-selection; a plain click selects the one tab.
      .pressDown(scale: 0.992) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
          send(.toggleSelection(tab.id))
        } else if flags.contains(.shift) {
          send(.extendSelection(to: tab.id))
        } else {
          send(.select(tab.id))
        }
      }
      .simultaneousGesture(TapGesture(count: 2).onEnded { rename(tab) })
      .contextMenu {
        if space.hasSelection, space.selection.contains(tab.id) {
          selectionMenu
        } else {
          tabMenu(tab)
        }
      }
      .tabIconPicker(tab.icon, isPresented: isPresented($iconTab, tab.id)) { send(.setIcon(tab.id, $0)) }
      .padding(.vertical, Self.rowGap)
      .landing(isLanding(.tab(tab.id)))
      .zone(.tab(tab.id), $zones)
  }

  private func rename(_ tab: Tab) {
    draftName = tab.displayTitle
    renamingTab = tab.id
  }

  private func editPinnedURL(_ tab: Tab) {
    guard let window = NSApp.keyWindow, let pinned = tab.pinnedURL else { return }
    presentModal(over: window) { dismiss in
      EditPinnedURLDialog(url: pinned.absoluteString, save: { send(.setPinnedURL(tab.id, $0)) }, dismiss: dismiss)
    }
  }

  private func finishRename(_ tab: Tab) {
    // Enter, Esc or a click elsewhere ends it once.
    guard renamingTab == tab.id else { return }
    send(.rename(tab.id, draftName == tab.title ? "" : draftName))
    renamingTab = nil
  }

  private func isPresented(_ value: Binding<UUID?>, _ id: UUID) -> Binding<Bool> {
    Binding { value.wrappedValue == id } set: { if !$0 { value.wrappedValue = nil } }
  }

  // The menu on a multi-selection: Copy Links | Mute | Open in Split View, Duplicate, Move to, New Folder with
  // N items | Archive Tabs, Archive Tabs Below (the Today rows under the last selected one).
  @ViewBuilder private var selectionMenu: some View {
    let tabs = space.selectedTabs
    Button("Copy Links") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(tabs.map(\.url.absoluteString).joined(separator: "\n"), forType: .string)
      store.send(.showToast("Copied item links"))
    }
    Divider()
    Button(tabs.allSatisfy(\.isMuted) ? "Unmute" : "Mute") {
      let mute = !tabs.allSatisfy(\.isMuted)
      for tab in tabs where tab.isMuted != mute { send(.toggleMute(tab.id)) }
    }
    Divider()
    // The selected tabs go beside the first of them, up to four panes.
    Button("Open in Split View") {
      for tab in tabs.dropFirst().prefix(Space.maxPanes - 1) { send(.split(tab.id, beside: tabs[0].id)) }
    }
    Button("Duplicate") { for tab in tabs { send(.duplicate(tab.id)) } }
    Menu("Move to") {
      Button("Pinned") { for tab in tabs { send(.move(tab.id, .pinned, before: nil)) } }
      Button("Today") { for tab in tabs { send(.move(tab.id, .unpinned, before: space.tabs(in: .unpinned).first?.id)) } }
      ForEach(space.folders) { folder in
        Button(folder.name) { for tab in tabs { send(.move(tab.id, .folder(folder.id), before: nil)) } }
      }
      Divider()
      ForEach(store.isIncognito ? [] : store.spaces.spaces.filter { $0.id != space.id }) { item in
        Button(item.name) { for tab in tabs { store.send(.spaces(.moveTab(tab.id, from: space.id, to: item.id))) } }
      }
    }
    if tabs.allSatisfy({ $0.placement == .unpinned }) {
      groupItems(tabs)
    }
    Button("New Folder with \(tabs.count) items") { newFolder(in: space.selectionContainer, with: tabs.map(\.id)) }
    Divider()
    Button("Archive Tabs") { send(.archive(tabs.map(\.id))) }
    let below = tabs.last { $0.placement == .unpinned }.map { space.todayNeighbors(of: $0.id).below } ?? []
    Button("Archive Tabs Below") { send(.archive(below)) }
      .disabled(below.isEmpty)
  }

  // Order: Copy Link, Share | Change Icon, Rename, Mute, Edit Pinned Page | Open in Split View, Duplicate, Move to |
  // Archive Tab and Archive Tabs Below, or Remove Favorite.
  @ViewBuilder private func tabMenu(_ tab: Tab) -> some View {
    let app = tab.placement == .favorite ? PreviewApp(tab.pinnedURL ?? tab.url) : nil
    if app == .calendar {
      LiveCalendarMenu(tab: tab)
      Divider()
    }
    Button("Copy Link") { copy(tab.url) }
    ShareMenu(url: tab.url)
    if app == .gmail {
      Divider()
      UnreadBadgeToggle()
    }
    Divider()
    Button("Change Icon…") { iconTab = tab.id }
    Button("Rename…") { rename(tab) }
    if tab.customTitle != nil || tab.icon != nil {
      Button("Reset Name and Icon") { send(.resetNameAndIcon(tab.id)) }
    }
    // Mutes a tab whether or not it is playing.
    Button(tab.isMuted ? "Unmute" : "Mute") { send(.toggleMute(tab.id)) }
    if tab.pinnedURL != nil {
      Menu("Edit Pinned Page") {
        Button("Replace Pinned URL with Current") { send(.replacePinnedURL(tab.id)) }
          .disabled(!tab.hasLeftPinnedURL)
        Button("Edit…") { editPinnedURL(tab) }
        Button("Back to Pinned URL") { send(.resetToPinnedURL(tab.id)) }
          .disabled(!tab.hasLeftPinnedURL)
      }
      if tab.hasLeftPinnedURL {
        Button("Separate From Pinned Tab") { send(.separateFromPinned(tab.id)) }
      }
    }
    Divider()
    if tab.placement == .unpinned || tab.placement == .pinned {
      Button(tab.placement == .pinned ? "Unpin Tab" : "Pin Tab") { send(.togglePin(tab.id)) }
    }
    if tab.placement == .unpinned {
      groupItems([tab])
    }
    // Always listed, dimmed when the tab is the selected one or already in its split.
    let splitBeside = space.selectedTabID.flatMap { selected in
      selected != tab.id && space.split(of: selected)?.tabIDs.contains(tab.id) != true ? selected : nil
    }
    Button("Open in Split View") { splitBeside.map { send(.split(tab.id, beside: $0)) } }
      .disabled(splitBeside == nil)
    Button("Duplicate") { send(.duplicate(tab.id)) }
    // An incognito window has no favorites.
    if tab.placement != .favorite, !store.isIncognito {
      Button("Favorite Tab") { send(.move(tab.id, .favorite, before: nil)) }
    }
    Menu("Move to") {
      if tab.placement != .favorite, !store.isIncognito {
        Button("Favorites") { send(.move(tab.id, .favorite, before: nil)) }
      }
      if tab.placement != .pinned {
        Button("Pinned") { send(.move(tab.id, .pinned, before: nil)) }
      }
      if tab.placement != .unpinned {
        Button("Today") { send(.move(tab.id, .unpinned, before: space.tabs(in: .unpinned).first?.id)) }
      }
      ForEach(space.folders.filter { tab.placement != .folder($0.id) }) { folder in
        Button(folder.name) { send(.move(tab.id, .folder(folder.id), before: nil)) }
      }
      Divider()
      // A favorite is already in every space of its profile, so it moves only to another profile's.
      ForEach(
        store.isIncognito
          ? [] : store.spaces.spaces.filter { $0.id != space.id && (tab.placement != .favorite || $0.profileID != space.profileID) }
      ) { item in
        Button(item.name) { store.send(.spaces(.moveTab(tab.id, from: space.id, to: item.id))) }
      }
    }
    Divider()
    if tab.placement == .favorite {
      // Unloads the favorite and takes it back to its pinned URL.
      Button("Close") { send(.close(tab.id)) }
        .disabled(!tab.isLive && !tab.hasLeftPinnedURL)
      Button("Remove Favorite") { send(.move(tab.id, .unpinned, before: space.tabs(in: .unpinned).first?.id)) }
    } else {
      Button("Archive Tab") { send(.archive([tab.id])) }
      if tab.placement == .unpinned {
        let (above, below) = space.todayNeighbors(of: tab.id)
        let others = space.otherTodayTabs(than: tab.id)
        Button("Archive Tabs Above") { send(.archive(above)) }
          .disabled(above.isEmpty)
        Button("Archive Tabs Below") { send(.archive(below)) }
          .disabled(below.isEmpty)
        Button("Archive Other Tabs") { send(.archive(others)) }
          .disabled(others.isEmpty)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 0) {
      // While a space is created, the footer shows only the dots, the new space's selected, where they were.
      LibraryButton(hover: libraryHover) { store.send(.toggleLibrary) }
        .contextMenu {
          Button("Clear Archive") { clearArchive() }.disabled(archive.isEmpty)
        }
        .opacity(isCreatingSpace ? 0 : 1)
        .allowsHitTesting(!isCreatingSpace)
      SpaceDots(
        store: store, hover: dotHover, dots: dots, isCreatingSpace: isCreatingSpace,
        editedIcon: isCreatingSpace || isEditingSpace ? iconPreview : nil, dropTarget: drag?.shownTarget,
        draggedDot: dotDrag?.id, zones: $zones,
        editTheme: { id in
          store.send(.spaces(.select(id)))
          editorPicker = .theme
          isEditingSpace = true
        },
        newFolder: { id in
          store.send(.spaces(.select(id)))
          newFolder()
        })
        // The dots share the room between the Library button and the plus, 3 pt clear of each.
        .padding(.horizontal, 3)
      // The plus: 14 pt across with a 2 pt stroke.
      IconButton(systemName: isMenuOpen ? "xmark" : "plus", size: 16.5, weight: .semibold) {
        menuHighlight = "New Tab"
        isMenuOpen.toggle()
      }
      .opacity(isCreatingSpace ? 0 : 1)
      .allowsHitTesting(!isCreatingSpace)
    }
    .padding(.horizontal, 10)
    .frame(height: 50)
  }

  // The spaces in the footer's order, which follows a dragged dot until it is dropped.
  private var dots: [Space] {
    if store.isIncognito { return [] }
    return dotDrag.map { $0.order.compactMap { store.spaces.spaces[id: $0] } } ?? store.spaces.spaces.elements
  }

  private var newItemMenu: some View {
    VStack(spacing: 0) {
      MenuRow(title: "New Space", systemName: "plus.square.on.square", highlight: $menuHighlight) {
        isMenuOpen = false
        isCreatingSpace = true
      }
      MenuRow(title: "New Folder", systemName: "folder", highlight: $menuHighlight) {
        isMenuOpen = false
        newFolder()
      }
      Rectangle().fill(Theme.menuSeparator).frame(height: 1).padding(.horizontal, 2).padding(.vertical, 8)
      MenuRow(title: "New Split", systemName: "rectangle.split.2x1", shortcut: "⌃⇧=", highlight: $menuHighlight) {
        isMenuOpen = false
        store.send(.newSplit)
      }
      .disabled(space.selectedTabID == nil)
      .opacity(space.selectedTabID == nil ? 0.5 : 1)
      MenuRow(title: "New Tab", systemName: "plus.square", shortcut: "⌘T", highlight: $menuHighlight) {
        isMenuOpen = false
        store.send(.showCommandBar)
      }
    }
    .padding(8)
    .frame(width: 222)
    .background(Theme.menu, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.06)))
    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
  }
}

private enum DragItem: Equatable {
  case tab(Tab.ID)
  case folder(Folder.ID)

  var id: UUID {
    switch self {
    case let .tab(id), let .folder(id): id
    }
  }

  var zone: Zone {
    switch self {
    case let .tab(id): .tab(id)
    case let .folder(id): .folder(id)
    }
  }
}

// A row of the sidebar's list below the space title.
private enum ListItem: Identifiable {
  case tab(Tab, depth: Int, isFolded: Bool)
  case folder(Folder, depth: Int, isFolded: Bool)
  // The insertion line where a dragged row would land.
  case group(TabGroup)
  case gap(DropTarget, depth: Int)
  case divider
  case newTab

  enum ID: Hashable {
    case row(UUID)
    case gap(DropTarget)
    case divider
    case newTab
  }

  var id: ID {
    switch self {
    case let .tab(tab, _, _): .row(tab.id)
    case let .folder(folder, _, _): .row(folder.id)
    case let .group(group): .row(group.id)
    case let .gap(target, _): .gap(target)
    case .divider: .divider
    case .newTab: .newTab
    }
  }

  // The rows that move when the list changes; the insertion line snaps instead.
  var rowID: ID? {
    if case .gap = self { return nil }
    return id
  }
}

private enum DropTarget: Hashable {
  // Before a row (a tab, or a folder in the pinned section), or at the end of the placement.
  case slot(Placement, before: UUID?)
  // Before a tab of a group, or at the group's end.
  case grouped(TabGroup.ID, before: Tab.ID?)
  case into(Folder.ID)
  case favorite(FavoriteSlot)
  // At a pane index of the tab's row.
  case split(beside: Tab.ID, at: Int)
  case space(Space.ID)

  var isFavorite: Bool {
    if case .favorite = self { return true }
    return false
  }

  var isSplit: Bool {
    if case .split = self { return true }
    return false
  }
}

// A space's section, built from the space as the store holds it. The strip's ForEach hands its content a
// value copy outside any view body, so a change inside the space (a folder toggled, the pinned section
// collapsed, a tab selected) reached no observer; here the reads happen in a body, against the current value.
private struct SpacePage<Content: View>: View {
  let store: StoreOf<WindowFeature>
  let id: Space.ID
  let content: (Space) -> Content

  var body: some View {
    if let space = store.spaces.spaces[id: id] {
      content(space).environment(\.spaceTheme, space.theme)
    }
  }
}

// A region of the sidebar that takes a drag, measured in the sidebar's coordinates.
private enum Zone: Hashable {
  static let space = "sidebar"

  case tab(Tab.ID)
  case folder(Folder.ID)
  case group(TabGroup.ID)
  case title
  case pinnedEnd
  case pinnedHint
  case newTab
  case list
  case favorites
  // The insertion line and the Favorites placeholder while a row is dragged.
  case line
  case placeholder
  case dot(Space.ID)
}

private struct Drag {
  let item: DragItem
  // The space the drag started in; resting on a space dot switches spaces mid-drag.
  let space: Space.ID
  let frame: CGRect
  // The pointer's place in the row at pick-up, as fractions of the row's size.
  let grab: CGPoint
  // The pointer, in the sidebar's coordinates.
  var location = CGPoint.zero
  var target: DropTarget
  // The pointer is over nothing that takes the drop, so releasing it there flies the copy back.
  var isOutside = false
  // The target the sidebar shows: none while the pointer is outside, or once a split drop's flash is over.
  var shownTarget: DropTarget? { isOutside || drop == .paused ? nil : target }
  // Released on a target: the copy is opaque, and the rows take the row motion.
  var isDropped = false
  // The tile size a copy dropped on the Favorites grid lands at.
  var landingSize: CGSize?
  // Where the copy settles once dropped.
  var landing: CGPoint?
  var isLanding: Bool { landing != nil }
  // A drop on a split target: the copy is gone, the half flashes, then the row shows plain until the split forms.
  var drop: SplitDrop?
  enum SplitDrop { case flashing, paused }
}

// A dragged tab resting on another tab's row: the row holds still until Motion.splitDwell has passed, then the
// pointer's half fills and the title keeps to the other half, in one frame; on release the half flashes solid.
private struct SplitHover: Equatable {
  // The pane the dragged tab would take, of the panes the row would then have.
  var index: Int
  var count: Int
  var phase: Phase
  enum Phase { case pending, armed, flashing }
}

private struct DotDrag {
  let id: Space.ID
  var order: [Space.ID]
  // The pointer's x in the sidebar's coordinates.
  var x: CGFloat = 0
}

extension EnvironmentValues {
  // Hover highlights stop while a row is dragged.
  @Entry var isDragging = false
}

private extension View {
  // Hidden at once, not faded, while the dragged copy lands on it.
  func landing(_ isLanding: Bool) -> some View {
    opacity(isLanding ? 0 : 1).animation(nil, value: isLanding)
  }

  // The split affordance: the half of the row the dragged tab will take fills once it has rested there, in one
  // frame, and flashes solid on release.
  func splitHalf(_ hover: SplitHover?) -> some View {
    overlay {
      if let hover, hover.phase != .pending {
        GeometryReader { geometry in
          let width = geometry.size.width / CGFloat(hover.count)
          RoundedRectangle(cornerRadius: 8)
            .fill(hover.phase == .flashing ? Theme.splitFlash : Theme.splitHalf)
            .padding(1)
            .frame(width: width)
            .offset(x: width * CGFloat(hover.index))
        }
      }
    }
  }

  // The New Tab label breathes in a space with no tabs yet; with Reduce Motion on it holds still.
  @ViewBuilder @MainActor func pulsing(_ isPulsing: Bool) -> some View {
    if isPulsing, let pulse = Motion.pulse {
      phaseAnimator([1.0, 0.4]) { view, phase in view.opacity(phase) } animation: { _ in pulse }
    } else {
      self
    }
  }

  // Folds a collapsed pinned section's rows up under the space title.
  func folded(_ isFolded: Bool) -> some View {
    frame(height: isFolded ? 0 : nil, alignment: .bottom)
      .clipShape(Rectangle().inset(by: isFolded ? 0 : -40))
      .opacity(isFolded ? 0 : 1)
      .allowsHitTesting(!isFolded)
  }

  func zone(_ zone: Zone, _ zones: Binding<Zones>) -> some View {
    modifier(ZoneReader(zone: zone, zones: zones.wrappedValue))
  }
}

private extension EnvironmentValues {
  // Only the selected space's section takes drags; the others are just shown while sliding.
  @Entry var isSelectedSpace = true
  // The theme a section's selected rows take their light from.
  @Entry var spaceTheme = SpaceTheme()
}

// The zones' frames, read in gesture callbacks and on drop. A reference, so that the rows reporting their frames
// during a swipe, a space switch or a resize do not re-evaluate the sidebar.
private final class Zones {
  var frames: [Zone: CGRect] = [:]
  var width: CGFloat = 0
}

private struct ZoneReader: ViewModifier {
  let zone: Zone
  let zones: Zones
  @Environment(\.isSelectedSpace) private var isSelected
  @State private var frame: CGRect?

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Zone.space)) } action: {
        frame = $0
        if isSelected {
          zones.frames[zone] = $0
        }
      }
      .onChange(of: isSelected) { _, isSelected in
        if isSelected {
          zones.frames[zone] = frame
        } else if zones.frames[zone] == frame {
          zones.frames[zone] = nil
        }
      }
      .onDisappear { if zones.frames[zone] == frame { zones.frames[zone] = nil } }
  }
}

private struct IconButton: View {
  let systemName: String
  // The hover plate's side: header buttons use 32 pt.
  var plate: CGFloat = 28
  // The sidebar toggle and reload glyphs are 18.5x15 and 14x17 pt, SF Symbols at 16 pt.
  var size: CGFloat = 16
  var weight: Font.Weight = .medium
  var isEnabled = true
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: size, weight: weight))
        .foregroundStyle(Theme.icon)
        .frame(width: plate, height: plate)
        .background(isHovering && isEnabled ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
    .buttonStyle(PressBounce())
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.6)
    .onHover { isHovering = $0 }
  }
}

// The shown row and the edge of the list it is scrolled past, if any.
private struct ShownRowEdge: Equatable {
  let tab: Tab.ID
  let edge: VerticalEdge?
}

// Buttons give a little on press and spring back.
private struct PressBounce: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.88 : 1)
      .animation(Motion.row, value: configuration.isPressed)
  }
}

// Tab rows and favorites act on the press, not the release, and give a little until the mouse comes up, a
// dragged row included. Buttons inside take their own presses. At 60 fps: rows to 0.992, tiles
// to 0.99, with no change of color.
private struct PressDown: ViewModifier {
  let scale: CGFloat
  let action: () -> Void
  @GestureState private var isPressed = false

  func body(content: Content) -> some View {
    content
      .scaleEffect(isPressed ? scale : 1)
      .animation(Motion.press, value: isPressed)
      .gesture(DragGesture(minimumDistance: 0).updating($isPressed) { _, pressed, _ in pressed = true })
      .onChange(of: isPressed) { _, pressed in if pressed { action() } }
  }
}

extension View {
  fileprivate func pressDown(scale: CGFloat, action: @escaping () -> Void) -> some View {
    modifier(PressDown(scale: scale, action: action))
  }
}

private struct SidebarRow<Content: View>: View {
  let isSelected: Bool
  // Room kept clear before the content, for the half a dragged tab will take.
  var leadingInset: CGFloat = 0
  @ViewBuilder let content: Content
  @Environment(\.isDragging) private var isDragging
  @Environment(\.spaceTheme) private var theme
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 10) { content }
    .font(.system(size: 14))
    .lineLimit(1)
    .padding(.horizontal, 10)
    .padding(.leading, leadingInset)
    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
    .background {
      // The fill changes at once even when a close moves the selection while rows slide.
      // The tab row: 12.04pt continuous.
      RoundedRectangle(cornerRadius: 12)
        .fill(isSelected ? Theme.rowSelection(theme) : isHovering && !isDragging ? Theme.rowHover : .clear)
        .shadow(color: isSelected ? Theme.rowShadow : .clear, radius: 2, y: 1.5)
        .animation(nil, value: isSelected)
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
  }
}

// A tab's favicon; before its page loads, the one history keeps for it.
struct TabFavicon: View {
  let tab: Tab
  let space: Space
  @State private var saved: NSImage?

  var body: some View {
    Group {
      if let favicon = tab.pageFavicon ?? saved {
        Image(nsImage: favicon).resizable().frame(width: 16, height: 16)
      } else {
        Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(Theme.icon)
      }
    }
    .task(id: tab.iconPage) {
      guard tab.pageFavicon == nil else { return }
      saved = await Autocomplete.favicon(space.profileID, space.isIncognito, tab.iconPage)
    }
  }
}

private struct TabRow: View {
  let tab: Tab
  let space: Space
  let isSelected: Bool
  // The name being typed while the tab is renamed.
  let name: Binding<String>?
  let endRename: (_ save: Bool) -> Void
  let backToPinnedURL: () -> Void
  // Highlighted with its X, as the dragged row and its copy are.
  var isLifted = false
  // A dragged tab resting on this row: once the half the row will split into shows, the title keeps clear of it.
  var splitHover: SplitHover? = nil
  var toggleMute: () -> Void = {}
  let close: () -> Void
  @Environment(\.isDragging) private var isDragging
  @State private var isHovering = false
  @State private var isIconHovered = false
  @State private var width: CGFloat = 0
  @FocusState private var isNameFocused: Bool

  var body: some View {
    SidebarRow(isSelected: isSelected || isLifted, leadingInset: splitHalfEnd) {
      // A pinned tab that left its pinned URL shows "favicon / title"; its favicon goes back.
      if tab.hasLeftPinnedURL {
        // The slash is 15 pt tall, centered 21.75 pt after the favicon's leading edge, with the title 28.5 pt after
        // it; hovering the favicon fills the row's leading 36 pt square and hides the slash.
        HStack(spacing: 4) {
          Button(action: backToPinnedURL) { icon }
            .buttonStyle(.plain)
            .background {
              UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                .fill(isIconHovered ? Theme.rowHover : .clear)
                .frame(width: 36, height: 36)
            }
            .onHover { isIconHovered = $0 }
          Text("/").font(.system(size: 16)).foregroundStyle(Theme.secondaryText).frame(width: 3.5)
            .opacity(isIconHovered ? 0 : 1)
        }
        .padding(.trailing, -5)
      } else {
        icon
      }
      if let name {
        TextField("", text: name)
          .textFieldStyle(.plain)
          .foregroundStyle(Theme.primaryText)
          .focused($isNameFocused)
          .onAppear { isNameFocused = true }
          .onSubmit { endRename(true) }
          .onExitCommand { endRename(false) }
          // A click elsewhere keeps the new name.
          .onChange(of: isNameFocused) { _, isFocused in if !isFocused { endRename(true) } }
      } else {
        VStack(alignment: .leading, spacing: 0) {
          // A long title ends in an ellipsis.
          Text(tab.displayTitle).foregroundStyle(Theme.rowText).frame(maxWidth: .infinity, alignment: .leading)
          if let subtitle {
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
          }
        }
        // The title stops where the split half begins: the row's width, less the icon and the paddings.
        .frame(maxWidth: splitHalfStart.map { max($0 - 46, 0) } ?? .infinity, alignment: .leading)
      }
      // A tab playing sound shows a speaker, which mutes it; a muted tab shows it struck through.
      if tab.isAudible || tab.isMuted {
        Button(action: toggleMute) {
          Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .font(.system(size: 11)).foregroundStyle(Theme.primaryText.opacity(0.8))
            .frame(width: 18, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.isMuted ? "Unmute" : "Mute")
      }
      if isHovering && !isDragging && name == nil || isLifted {
        Spacer(minLength: 0)
        Button(action: close) {
          // The "−" unloads a loaded pinned tab. Its X is 11 pt across and its "−" a 14 x 2 pt bar, both in the
          // row's lavender, 17.5 pt from the row's end.
          Group {
            if tab.pinnedURL != nil && tab.isLive {
              Rectangle().frame(width: 14, height: 2)
            } else {
              Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
            }
          }
          .foregroundStyle(Theme.rowText.opacity(0.8))
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, -3.5)
      }
    }
    .overlay {
      // The developer outline: 2 pt dashes, 7.5 pt of #FFCE1C then 7.5 pt of #3A3011, just outside the row.
      if tab.url.isDeveloperPage {
        ZStack {
          RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0x3A3011), lineWidth: 2)
          RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0xFFCE1C), style: StrokeStyle(lineWidth: 2, dash: [7.5, 7.5]))
        }
        .padding(-2)
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .onHover { isHovering = $0 }
    .hoverTooltip(tab.displayTitle, isEnabled: name == nil)
  }

  // Where the split half the dragged tab will take begins, once it is shown to the title's right.
  private var splitHalfStart: CGFloat? {
    guard let splitHover, splitHover.phase != .pending, splitHover.index == splitHover.count - 1 else { return nil }
    return width * CGFloat(splitHover.index) / CGFloat(splitHover.count)
  }

  // Where the split half the dragged tab will take ends, once it is shown to the title's left: the icon and
  // title move over into the other half.
  private var splitHalfEnd: CGFloat {
    guard let splitHover, splitHover.phase != .pending, splitHover.index == 0 else { return 0 }
    return width / CGFloat(splitHover.count)
  }

  private var subtitle: String? {
    if isIconHovered { return "Back to Pinned URL" }
    // Developer mode adds the host.
    if tab.url.isDeveloperPage { return tab.url.developerSubtitle }
    return isSelected && tab.pinnedURL != nil ? "Double-click to rename" : nil
  }

  private var icon: some View {
    Group {
      if tab.isLoading, tab.icon == nil {
        RoundedRectangle(cornerRadius: 3).fill(Theme.fillHover).frame(width: 14, height: 14)
      } else {
        TabIcon(tab: tab, space: space)
      }
    }
    .frame(width: 16)
    // Dims an unloaded pinned tab's favicon.
    .opacity(tab.pinnedURL != nil && !tab.isLive ? 0.5 : 1)
  }
}

// Share ▸: the system's sharing services for the link.
private struct ShareMenu: View {
  let url: URL

  var body: some View {
    Menu("Share") {
      ForEach(NSSharingService.sharingServices(forItems: [url]), id: \.title) { service in
        Button { service.perform(withItems: [url]) } label: {
          Label { Text(service.menuItemTitle) } icon: { Image(nsImage: service.image) }
        }
      }
    }
  }
}

// The tab's own icon if it was given one, else its favicon.
private struct TabIcon: View {
  let tab: Tab
  let space: Space

  var body: some View {
    if let icon = tab.icon {
      SpaceIcon(icon: icon, emojiSize: 15)
    } else {
      TabFavicon(tab: tab, space: space)
    }
  }
}

private extension View {
  // Change Icon…: the space icon picker, with Remove Icon going back to the favicon.
  func tabIconPicker(_ icon: String?, isPresented: Binding<Bool>, set: @escaping (String?) -> Void) -> some View {
    popover(isPresented: isPresented, arrowEdge: .trailing) {
      IconPicker(icon: Binding { icon ?? "" } set: { set($0.isEmpty ? nil : $0) })
    }
  }
}

// Window buttons: gray until the pointer is over them, then colored with their glyphs.
struct TrafficLights: View {
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 8) {
      light(0xFF5F57, "xmark", #selector(NSWindow.performClose(_:)))
      light(0xFEBC2E, "minus", #selector(NSWindow.performMiniaturize(_:)))
      light(0x28C840, "arrow.up.left.and.arrow.down.right", #selector(NSWindow.toggleFullScreen(_:)))
    }
    .padding(.leading, 14)
    .onHover { isHovering = $0 }
  }

  private func light(_ color: UInt32, _ glyph: String, _ action: Selector) -> some View {
    Button { NSApp.sendAction(action, to: nil, from: nil) } label: {
      Circle()
        .fill(isHovering ? Color(hex: color) : Theme.trafficLight)
        .frame(width: 12, height: 12)
        .overlay {
          if isHovering {
            Image(systemName: glyph).font(.system(size: 7, weight: .heavy)).foregroundStyle(.black.opacity(0.55))
          }
        }
    }
    .buttonStyle(.plain)
  }
}

// The permission popover on the URL pill.
private struct PermissionPrompt: View {
  let request: PermissionRequest

  var body: some View {
    // Shot 53: the circle 11 pt in from the top and leading edges, the text 9 pt past it in 14 pt lines 17 apart,
    // and two 104 x 32 buttons 8 apart, 15 pt below the text and 10 above the bottom.
    VStack(spacing: 15) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: request.isLocation ? "location.fill" : "lock.fill")
          .font(.system(size: 13))
          .frame(width: 32, height: 32)
          .background(.quaternary, in: Circle())
        Text(request.message).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        button("Not Now", fill: 0.06) { request.answer(false) }
        button("Allow", fill: 0.36) { request.answer(true) }
      }
    }
    .padding(.horizontal, 9)
    .padding(.top, 11)
    .padding(.bottom, 10)
    .frame(width: 236)
  }

  // Shot 53: Not Now a faint fill, Allow a light one, both with 14 pt semibold titles.
  private func button(_ title: String, fill: Double, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 32)
        .background(.white.opacity(fill), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct SpaceDot: View {
  let icon: String
  let isSelected: Bool
  // The dot a drag has lifted, drawn a lighter gray.
  var isLifted = false
  // Another dot is under the pointer: the selected space then shows as a small dot, its icon put away.
  var isOtherHovered = false
  // A crowded footer draws the other spaces' dots at 4 pt; with room, every dot is 8 pt.
  var isCrowded = false
  @Environment(\.isDragging) private var isDragging
  @State private var isHovering = false

  var body: some View {
    Group {
      // The footer shows a space's icon only while it is the selected one (the icon spans about 15 pt where a
      // selected dot is 8 pt); every other space is a dot, whatever its icon.
      if icon.isEmpty || !isSelected || isOtherHovered {
        let isLarge = !isCrowded || isSelected && !isOtherHovered || isHovering && !isDragging
        let size: CGFloat = isLarge ? 8 : 4
        Circle().frame(width: size, height: size)
      } else {
        SpaceIcon(icon: icon, size: 15)
      }
    }
    // The hovered dot is drawn as the current one: 8 pt and dark, settling in about 0.15 s; nothing
    // is drawn behind it, and the selected space's icon does not change.
    .foregroundStyle(
      isLifted ? Theme.spaceDot.opacity(0.6) : isSelected || isHovering && !isDragging ? Theme.spaceDot : Theme.spaceDotOther)
    .frame(maxWidth: .infinity, minHeight: 20)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.15), value: isHovering)
  }
}

// Whether the pointer is on the Library button or on the download stack it shows.
@Observable private final class LibraryHover {
  var isOnButton = false
  var isOnStack = false
}

// The footer's Library button: a box glyph, with the badge of a running download over its top right, or for half
// a minute the icon of the one that just finished, lifted clear of the glyph.
private struct LibraryButton: View {
  let hover: LibraryHover
  let action: () -> Void
  @Environment(StoreOf<DownloadsFeature>.self) private var downloads
  @Environment(DownloadThrows.self) private var downloadThrows
  @State private var isHovering = false
  // Each kind of file's icon, read from the system while its download runs, so the body only looks it up.
  @State private var icons: [UTType: NSImage] = [:]
  @Shared(.mediaSources) private var mediaSources

  var body: some View {
    let shape = Motion.downloadThrow
    let progress = downloads.downloads.progress
    // The stack shows it while the pointer is on the button.
    let isStackShown = hover.isOnButton || hover.isOnStack
    let finished = isStackShown ? nil : downloads.finished.flatMap { downloads.downloads[id: $0] }
    Button(action: action) {
      LibraryGlyph()
        .foregroundStyle(Theme.icon)
        .frame(width: 28, height: 28)
        .background(isHovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .topTrailing) {
      // A download starting takes the file's icon off at once and fades its badge in; one finishing takes the badge
      // off at once and pops its file's icon in from larger.
      ZStack {
        if let progress {
          DownloadRing(progress: progress).transition(.asymmetric(insertion: .opacity, removal: .identity))
        } else if let finished, let icon = icons[finished.type] {
          Image(nsImage: icon)
            .resizable()
            .frame(width: 25, height: 25)
            .offset(y: -11.5)
            .transition(.asymmetric(insertion: .scale(scale: shape.iconPop), removal: .identity))
        }
      }
      .frame(width: 20, height: 20)
      .animation(progress == nil ? shape.pop : shape.badge, value: progress == nil)
      .onChange(of: Set(downloads.downloads.map(\.type)), initial: true) { _, types in
        for type in types where icons[type] == nil { icons[type] = NSWorkspace.shared.icon(for: type) }
      }
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DownloadThrows.space)) } action: {
        downloadThrows.badge = $0
      }
      // Centered on the glyph's top right corner, at (21, 5.5) in the 28 pt button.
      .offset(x: 3, y: -4.5)
      .allowsHitTesting(false)
    }
    .onHover {
      isHovering = $0
      hover.isOnButton = $0
    }
    .hoverTooltip("View Library", subtitle: "⇧⌘L")
    // Right-click: where the Library's Media comes from.
    .contextMenu {
      Section("Show media from:") {
        ForEach(MediaSources.allCases, id: \.rawValue) { source in
          Toggle(source.title, isOn: Binding {
            mediaSources.contains(source)
          } set: { isOn in
            $mediaSources.withLock { isOn ? $0.formUnion(source) : $0.subtract(source) }
          })
        }
      }
    }
  }
}

// Hovering the Library button shows the latest downloads above it, newest at the bottom, running ones included.
private struct DownloadStack: View {
  let hover: LibraryHover
  @Environment(StoreOf<DownloadsFeature>.self) private var downloads

  var body: some View {
    let recent = downloads.downloads.filter { $0.state != .cancelled }
    if hover.isOnButton || hover.isOnStack, !recent.isEmpty {
      DownloadStackRows(rows: Array(recent.prefix(4).reversed())) { downloads.send(.cancel($0)) }
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 2)
        // Bridges the gap down to the button's top, so the pointer can reach the rows without the stack closing.
        .padding(.bottom, 5)
        .contentShape(Rectangle())
        .onHover { hover.isOnStack = $0 }
        // The bottom row's centre sits 42 pt above the button's, which is 25 pt above the bottom.
        .padding(.bottom, 34)
    }
  }
}

// The stack's rows, which rise out of the Library button as they fade in: each starts on the button's centre.
private struct DownloadStackRows: View {
  let rows: [Download]
  let cancel: (Download.ID) -> Void
  @State private var isRisen = false
  // Rows 56 pt apart, the bottom one centred 42 pt above the button.
  private static let pitch = 56.0
  private static let firstRise = 42.0

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, download in
        DownloadRow(download: download) { cancel(download.id) }
          .offset(y: isRisen ? 0 : Self.firstRise + Self.pitch * Double(rows.count - 1 - index))
          .opacity(isRisen ? 1 : 0)
      }
    }
    .onAppear { withAnimation(Motion.downloadStack) { isRisen = true } }
  }
}

// "Share Quote" under the URL while text is selected in the page; only this label follows the selection.
private struct ShareQuoteLabel: View {
  let tab: Tab.ID
  let accent: Color

  var body: some View {
    if Engine.shared.selections[tab] != nil {
      Text("Share Quote").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
    }
  }
}

// The footer dot under the pointer, and the one whose tooltip shows.
@Observable private final class DotHover {
  var hovered: Space.ID?
  var tip: Space.ID?
}

// The footer's space dots. They own the dot hover, so it redraws only this row.
private struct SpaceDots: View {
  let store: StoreOf<WindowFeature>
  let hover: DotHover
  let dots: [Space]
  let isCreatingSpace: Bool
  // The icon picked in the open space editor: the new space's dot, or the edited space's.
  let editedIcon: String?
  let dropTarget: DropTarget?
  let draggedDot: Space.ID?
  @Binding var zones: Zones
  // Edit Theme Color… and New Folder on a dot first switch to its space.
  let editTheme: (Space.ID) -> Void
  let newFolder: (Space.ID) -> Void
  @State private var pickingIcon: Space.ID?
  @State private var width: CGFloat = 0

  // The footer: each space gets an equal slot of at most 34 pt; under 22 pt the selected space keeps 22 and the
  // others share the rest.
  private static func slots(width: CGFloat, count: Int) -> (selected: CGFloat, other: CGFloat) {
    let even = min(34, width / CGFloat(max(count, 1)))
    guard even < 22, count > 1 else { return (even, even) }
    return (22, (width - 22) / CGFloat(count - 1))
  }

  var body: some View {
    let count = dots.count + (isCreatingSpace ? 1 : 0)
    let selected = isCreatingSpace ? nil : store.spaces.selectedID
    let slots = Self.slots(width: width, count: count)
    let isCrowded = slots.other < 22
    HStack(spacing: 0) {
      // No dot for a lone space.
      if count > 1 {
        dotViews(selected: selected, slots: slots, isCrowded: isCrowded)
      }
      if isCreatingSpace {
        SpaceDot(icon: editedIcon ?? "", isSelected: true, isCrowded: isCrowded).frame(width: slots.selected)
      }
    }
    .frame(maxWidth: .infinity)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .task(id: hover.hovered) {
      // Once a tooltip shows, moving to the next dot updates it at once.
      guard let hovered = hover.hovered else {
        hover.tip = nil
        return
      }
      if hover.tip == nil, (try? await Task.sleep(for: .milliseconds(500))) == nil { return }
      hover.tip = hovered
    }
    // A switch by click, key or swipe takes the tooltip down until the pointer comes back.
    .onChange(of: store.spaces.selectedID) { hide() }
  }

  private func dotViews(selected: Space.ID?, slots: (selected: CGFloat, other: CGFloat), isCrowded: Bool) -> some View {
    ForEach(dots) { item in
      SpaceDot(
        icon: item.id == selected ? editedIcon ?? item.icon : item.icon,
        isSelected: item.id == selected || dropTarget == .space(item.id),
        isOtherHovered: hover.hovered != nil && hover.hovered != item.id, isCrowded: isCrowded)
        .frame(width: item.id == selected ? slots.selected : slots.other)
        .opacity(draggedDot == item.id ? 0 : 1)
        .onTapGesture {
          hide()
          store.send(.spaces(.select(item.id)))
        }
        .onHover { hover.hovered = $0 ? item.id : hover.hovered == item.id ? nil : hover.hovered }
        .contextMenu {
          SpaceMenu(
            store: store, space: item, changeIcon: { pickingIcon = item.id }, editTheme: { editTheme(item.id) },
            newFolder: { newFolder(item.id) }, shareAnchor: { zones.frames[.dot(item.id)] })
        }
        // The icon picker opens over the dot, without switching to its space.
        .popover(
          isPresented: Binding { pickingIcon == item.id } set: { if !$0 { pickingIcon = nil } }, arrowEdge: .top
        ) {
          IconPicker(icon: Binding { item.icon } set: { icon in
            store.send(.spaces(.update(item.id, name: item.name, icon: icon, theme: item.theme)))
          })
        }
        .zone(.dot(item.id), $zones)
    }
  }

  private func hide() {
    hover.hovered = nil
    hover.tip = nil
  }
}

private struct SpaceTipOverlay: View {
  let store: StoreOf<WindowFeature>
  let hover: DotHover

  var body: some View {
    if let tip = hover.tip, let index = store.spaces.spaces.index(id: tip) {
      let item = store.spaces.spaces[index]
      SpaceTip(name: item.name, profile: store.spaces.profiles[id: item.profileID]?.name, number: index < 9 ? index + 1 : nil)
        // The pill starts 8 pt in from the window's edge.
        .padding(.leading, 8)
        .padding(.bottom, 45)
        .allowsHitTesting(false)
    }
  }
}

// The space dot tooltip: the space's name, its profile and its ⌃N shortcut.
private struct SpaceTip: View {
  let name: String
  let profile: String?
  let number: Int?
  private let ink = Theme.accentInk
  private let chip = Theme.accentTint

  var body: some View {
    HStack(spacing: 8) {
      // 12 pt semibold name and 11 pt semibold profile: their 2x ink widths (83 and 103 pt) in the dot tooltip frame.
      Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
      if let profile {
        HStack(spacing: 4) {
          Image(systemName: "face.smiling").font(.system(size: 13, weight: .medium))
            .background(Theme.accent.opacity(0.25), in: Circle())
          Text(profile).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(chip, in: Capsule())
      }
      if let number {
        HStack(spacing: 3.5) {
          keycap("⌃")
          keycap("\(number)")
        }
      }
    }
    .lineLimit(1)
    .padding(.leading, 10.5)
    .padding(.trailing, 9.5)
    .frame(height: 27)
    .tooltipPill()
    .fixedSize()
  }

  private func keycap(_ glyph: String) -> some View {
    Text(glyph).font(.system(size: 11, weight: .bold)).foregroundStyle(ink)
      // The key: a 17 x 15.5 pt face in a 1 pt rim with a 2.5 pt lower edge, 19 pt square.
      .frame(width: 17, height: 15.5)
      .background(chip, in: RoundedRectangle(cornerRadius: 3.5))
      .padding([.horizontal, .top], 1)
      .padding(.bottom, 2.5)
      .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4.5))
  }
}

private struct MenuRow: View {
  let title: String
  let systemName: String
  var shortcut: String?
  @Binding var highlight: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: systemName).font(.system(size: 15)).frame(width: 20)
        Text(title).font(.system(size: 13, weight: .semibold))
        Spacer()
        if let shortcut {
          Text(shortcut).font(.system(size: 12)).foregroundStyle(Theme.menuShortcut)
        }
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 10)
      .frame(height: 40)
      .background(highlight == title ? Theme.menuSelection : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { if $0 { highlight = title } }
  }
}

// The swipe past the last space: a plus slides in from the edge while its ring fills, then turns white
// once lifting would create a space.
private struct CreateSpaceRing: View {
  let progress: CGFloat
  private var isArmed: Bool { progress >= 1 }

  var body: some View {
    ZStack {
      Circle().fill(isArmed ? Theme.accentTint : Theme.accent).padding(isArmed ? 0 : 2.5)
      Circle().trim(from: 0, to: min(progress, 1)).stroke(Theme.accentTint, lineWidth: 2.5)
        .rotationEffect(.degrees(-90)).scaleEffect(x: -1).padding(1.25)
      Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
        .foregroundStyle(isArmed ? Theme.accent : .white)
    }
    .frame(width: 30, height: 30)
    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    .animation(Motion.layout, value: isArmed)
    // It is in place by about half the way, 8.5 pt from the edge, over a light that grows toward the edge.
    .padding(.trailing, 8.5)
    .offset(x: 38.5 * (1 - min(progress / 0.55, 1)))
    .frame(maxHeight: .infinity)
    .background(alignment: .trailing) {
      LinearGradient(colors: [.clear, .white.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
        .frame(width: 90).opacity(min(progress, 1))
    }
    .sensoryFeedback(.alignment, trigger: isArmed) { _, isArmed in isArmed }
    .allowsHitTesting(false)
  }
}

// Edit Pinned URL: the page a pinned tab or favorite opens first.
private struct EditPinnedURLDialog: View {
  @State var url: String
  let save: (URL) -> Void
  let dismiss: () -> Void

  private var parsed: URL? {
    URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.scheme != nil && $0.host() != nil ? $0 : nil }
  }

  var body: some View {
    ConfirmModal(
      confirm: "Save", isValid: parsed != nil,
      onConfirm: {
        parsed.map(save)
        dismiss()
      },
      onCancel: dismiss
    ) {
      Text("Edit Pinned URL").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
      ModalField(placeholder: "https://", text: $url).padding(.top, 20)
    }
    .frame(width: 450)
  }
}

// A favorite: its icon on a tile that lights on hover, and shows the selection when it is the current tab.
private struct FavoriteTile: View {
  let tab: Tab
  let space: Space
  @Environment(\.isDragging) private var isDragging
  @State private var isHovering = false

  var body: some View {
    TabIcon(tab: tab, space: space)
      .frame(maxWidth: .infinity)
      // The tile is 47 pt tall.
      .frame(height: 47)
      .background { background(RoundedRectangle(cornerRadius: 12)) }
      .onHover { isHovering = $0 }
  }

  // The favorites tile: 12.05pt continuous. Selected, it is lit with the space's primary color and ringed 2 pt inside
  // its edge with the theme's colors; on a dark theme they also warm the fill.
  @ViewBuilder private func background(_ shape: RoundedRectangle) -> some View {
    if tab.id == space.selectedTabID {
      let ring = Theme.favoriteRing(space.theme)
      shape.fill(Theme.rowSelection(space.theme))
        .overlay(shape.fill(ring).opacity(Theme.isLight(space.theme) ? 0 : 0.15))
        .overlay(shape.strokeBorder(ring, lineWidth: 2))
    } else {
      shape.fill(isHovering && !isDragging ? Theme.fillHover : Theme.fill)
    }
  }
}

// Asks before a space moves to another profile, as its pages start there signed out.
struct SwitchProfileDialog: View {
  let space: String
  let profile: String
  let switchProfile: () -> Void
  let dismiss: () -> Void

  var body: some View {
    ConfirmModal(
      confirm: "Switch Profile", isValid: true,
      onConfirm: {
        dismiss()
        switchProfile()
      },
      onCancel: dismiss
    ) {
      Text("Use the “\(profile)” Profile for “\(space)”?").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
      Text(
        "This Space will start fresh in that Profile — so you'll have to log back in to websites, and its tabs "
          + "reload there. You can always switch back."
      )
      .font(.system(size: 14)).padding(.top, 14)
    }
    .frame(width: 450)
  }
}
