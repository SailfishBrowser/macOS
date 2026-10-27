import ComposableArchitecture
import Foundation

typealias Space = TabsFeature.State

// A space's name, icon and theme before an edit, so that undo can put them back.
struct SpaceEdit: Equatable {
  let name: String
  let icon: String
  let theme: SpaceTheme
}

// A folder turned into a space: the space, where the folder came from, and its rows as they were, for undo.
struct FolderConversion: Equatable {
  let space: Space.ID
  let source: Space.ID
  let rows: [PinnedRow]
  let pinnedOrder: [UUID]
}

// A space turned into a folder: the space as it was, where it sat, and the folder it became, for undo.
struct SpaceConversion: Equatable {
  let space: Space
  let index: Int
  let folder: Folder.ID
  let target: Space.ID
}

struct Profile: Codable, Equatable, Identifiable {
  let id: UUID
  var name: String
  // Today tabs not shown for this long are archived; the default is 12 hours, and nil is Never.
  var archiveAfter: TimeInterval? = 12 * 3600
  // Favorites belong to the profile: every space of the profile shows them, and a favorite is one page
  // wherever it is shown.
  var favorites: IdentifiedArrayOf<Tab> = []
  // Favorites in rows, each row's tiles sharing the width.
  var favoriteRows: [[Tab.ID]] = []
}

extension SharedKey where Self == InMemoryKey<IdentifiedArrayOf<Profile>>.Default {
  static var profiles: Self { Self[.inMemory("profiles"), default: []] }
}

extension Space {
  // The first space's icon is a sailboat.
  static let primaryIcon = "sail"
}

@Reducer
struct SpacesFeature {
  @ObservableState
  struct State: Codable, Equatable {
    var spaces: IdentifiedArrayOf<Space>
    var selectedID: Space.ID
    @Shared(.profiles) var profiles

    var selected: Space { spaces[id: selectedID]! }

    enum CodingKeys: String, CodingKey {
      case _spaces = "spaces", _selectedID = "selectedID"
    }
  }

  enum Action {
    case create(name: String, icon: String, theme: SpaceTheme, profile: Profile.ID)
    case cycle(Int)
    case delegate(Delegate)
    // Removes the space, archiving its tabs.
    case delete(Space.ID)
    // Turn "…" into Space: a space named after the folder, holding what it held.
    case folderToSpace(Folder.ID, in: Space.ID)
    // Moves a folder and everything in it to the top of another space's pinned section.
    case moveFolder(Folder.ID, from: Space.ID, to: Space.ID)
    // Moves a space to an index in the order of the dots, ⌃1–9 and the Spaces menu.
    case moveSpace(Space.ID, to: Int)
    // Moves a tab to the top of its section in another space; a folder's tab becomes pinned, and a favorite
    // becomes one of the other profile's.
    case moveTab(Tab.ID, from: Space.ID, to: Space.ID)
    // An ⌥-drop into another space: the tab stays and an unloaded copy lands in the other space, before a row of a
    // placement (nil: the top of the tab's own section, as a drop on the space's dot).
    case copyTab(Tab.ID, from: Space.ID, to: Space.ID, placement: Placement? = nil, before: UUID? = nil)
    // Puts a deleted space back where it was and takes its tabs out of the archive.
    case restore(Space, at: Int)
    // Puts a folder turned into a space back where it was; what the space gained since joins the folder.
    case undoFolderToSpace(FolderConversion)
    // Turn into Folder: the space becomes a folder at the top of another space's pinned section, holding
    // everything it held.
    case spaceToFolder(Space.ID, into: Space.ID)
    // Puts a space turned into a folder back where it was; what the folder gained since joins the space.
    case undoSpaceToFolder(SpaceConversion)
    case select(Space.ID)
    // Moves the space to another profile; its pages load again in it.
    case setProfile(Space.ID, Profile.ID)
    case spaces(IdentifiedActionOf<TabsFeature>)
    case update(Space.ID, name: String, icon: String, theme: SpaceTheme)
    // Undoes an edit of the space's name, icon or theme.
    case revert(Space.ID, SpaceEdit)

    @CasePathable
    enum Delegate {
      case deleted(Space, at: Int)
      case folderTurnedIntoSpace(FolderConversion)
      case spaceTurnedIntoFolder(SpaceConversion)
      // Pages moved under another profile reload with its browser data, which a notice points out.
      case movedAcrossProfiles
      // The space's name, icon or theme changed; what they were, for undo.
      case edited(Space.ID, SpaceEdit)
    }
  }

  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid
  @Dependency(\.webEngine) var engine

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .create(name, icon, theme, profile):
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .none }
        let space = Space(
          id: uuid(), name: name, profileID: profile, createdAt: now, isIncognito: state.selected.isIncognito,
          icon: icon, theme: theme
        )
        // A new space goes beside the one in use.
        state.spaces.insert(space, at: state.spaces.index(id: state.selectedID).map { $0 + 1 } ?? state.spaces.endIndex)
        return select(space.id, &state)

      case let .cycle(offset):
        let index = state.spaces.index(id: state.selectedID)!
        return select(state.spaces[(index + offset + state.spaces.count) % state.spaces.count].id, &state)

      case .delegate:
        return .none

      case let .delete(id):
        guard state.spaces.count > 1, let index = state.spaces.index(id: id) else { return .none }
        // Its favorites stay with the profile.
        var space = state.spaces.remove(at: index)
        let live = space.ownTabs.filter(\.isLive).map(\.id)
        for tab in space.ownTabs {
          space.ownTabs[id: tab.id]?.isLive = false
          space.ownTabs[id: tab.id]?.isLoading = false
        }
        if !space.isIncognito {
          @Shared(.archive) var archive
          let archived = space.ownTabs.map {
            ArchivedTab(id: $0.id, url: $0.url, title: $0.displayTitle, profileID: space.profileID, archivedAt: now)
          }
          $archive.withLock { $0.insert(contentsOf: archived, at: 0) }
        }
        let effects: Effect<Action> = .merge(
          .run { _ in for tab in live { await engine.close(tab) } },
          .send(.delegate(.deleted(space, at: index)))
        )
        guard state.selectedID == id else { return effects }
        return .merge(effects, select(state.spaces[max(index - 1, 0)].id, &state))

      case let .folderToSpace(id, source):
        guard let index = state.spaces.index(id: source), let folder = state.spaces[index].folders[id: id] else {
          return .none
        }
        let old = state.spaces[index]
        let taken = state.spaces[index].takeFolder(id)
        var space = Space(
          id: uuid(), name: folder.name, profileID: old.profileID, createdAt: now, isIncognito: old.isIncognito,
          icon: folder.icon ?? "", theme: old.theme)
        space.add(Array(taken.dropFirst()), from: .folder(id))
        space.selectedTabID = old.selectedTabID.flatMap { space.tabs[id: $0]?.id }
        state.spaces.insert(space, at: index + 1)
        let conversion = FolderConversion(space: space.id, source: source, rows: taken, pinnedOrder: old.pinnedOrder)
        return .merge(select(space.id, &state), .send(.delegate(.folderTurnedIntoSpace(conversion))))

      case let .undoFolderToSpace(conversion):
        guard let created = state.spaces.remove(id: conversion.space), state.spaces[id: conversion.source] != nil else {
          return .none
        }
        let folder = conversion.rows[0].id
        var tabs = created.ownTabs
        for row in conversion.rows {
          switch row {
          case let .folder(folder):
            state.spaces[id: conversion.source]?.folders.append(folder)
          case var .tab(tab):
            // The tab as it is now, back in its row.
            if let current = tabs.remove(id: tab.id) {
              tab = current
              tab.placement = row.placement
            }
            state.spaces[id: conversion.source]?.tabs.append(tab)
          }
        }
        for extra in created.folders where !conversion.rows.contains(where: { $0.id == extra.id }) {
          var extra = extra
          extra.placement = extra.placement == .pinned ? .folder(folder) : extra.placement
          state.spaces[id: conversion.source]?.folders.append(extra)
        }
        for var tab in tabs {
          tab.placement = tab.placement.isPinnedSection ? .folder(folder) : tab.placement
          state.spaces[id: conversion.source]?.tabs.append(tab)
        }
        state.spaces[id: conversion.source]?.pinnedOrder = conversion.pinnedOrder
        return select(conversion.source, &state)

      case let .spaceToFolder(id, target):
        guard
          id != target, let index = state.spaces.index(id: id), let source = state.spaces[id: id],
          let destination = state.spaces[id: target]
        else { return .none }
        state.spaces.remove(id: id)
        let folder = Folder(id: uuid(), name: source.name, placement: .pinned, icon: source.icon.isEmpty ? nil : source.icon)
        // Pinned rows keep their nesting under the folder and Today tabs become its pinned tabs. Favorites belong to
        // the profile and stay there.
        let reloads = destination.profileID != source.profileID
        var unloaded: [Tab.ID] = []
        func moved(_ tab: Tab, to placement: Placement) -> Tab {
          var tab = tab
          tab.placement = placement
          tab.pinnedURL = tab.pinnedURL ?? tab.url
          if reloads, tab.isLive {
            unloaded.append(tab.id)
            tab.isLive = false
            tab.isLoading = false
          }
          return tab
        }
        let rows = source.tree().map { row -> PinnedRow in
          switch row {
          case var .folder(nested):
            nested.placement = nested.placement == .pinned ? .folder(folder.id) : nested.placement
            return .folder(nested)
          case let .tab(tab):
            return .tab(moved(tab, to: tab.placement == .pinned ? .folder(folder.id) : tab.placement))
          }
        } + source.tabs(in: .unpinned).map { .tab(moved($0, to: .folder(folder.id))) }
        state.spaces[id: target]?.add([.folder(folder)] + rows)
        let conversion = SpaceConversion(space: source, index: index, folder: folder.id, target: target)
        return .merge(
          .run { [unloaded] _ in for tab in unloaded { await engine.close(tab) } },
          state.selectedID == id ? select(target, &state) : .none,
          .send(.delegate(.spaceTurnedIntoFolder(conversion)))
        )

      case let .undoSpaceToFolder(conversion):
        guard state.spaces[id: conversion.space.id] == nil, let target = state.spaces[id: conversion.target] else {
          return .none
        }
        let rows = state.spaces[id: conversion.target]!.takeFolder(conversion.folder).dropFirst()
        var space = conversion.space
        space.ownTabs = []
        space.folders = []
        let reloads = target.profileID != space.profileID
        var unloaded: [Tab.ID] = []
        for row in rows {
          switch row {
          case var .folder(folder):
            // A folder the space had goes back where it was; one added since sits in the pinned section.
            folder.placement = conversion.space.folders[id: folder.id]?.placement
              ?? (folder.placement == .folder(conversion.folder) ? .pinned : folder.placement)
            space.folders.append(folder)
          case var .tab(tab):
            tab.placement = conversion.space.ownTabs[id: tab.id]?.placement
              ?? (tab.placement == .folder(conversion.folder) ? .pinned : tab.placement)
            tab.pinnedURL = tab.placement == .unpinned ? nil : tab.pinnedURL
            if reloads, tab.isLive {
              unloaded.append(tab.id)
              tab.isLive = false
              tab.isLoading = false
            }
            space.ownTabs.append(tab)
          }
        }
        space.selectedTabID = space.selectedTabID.flatMap { space.tabs[id: $0]?.id }
        state.spaces.insert(space, at: min(conversion.index, state.spaces.count))
        return .merge(
          .run { [unloaded] _ in for tab in unloaded { await engine.close(tab) } },
          .send(.spaces(.element(id: conversion.target, action: .activate))),
          select(space.id, &state)
        )

      case let .moveFolder(id, from, to):
        guard from != to, let target = state.spaces[id: to], let source = state.spaces[id: from] else { return .none }
        var rows = state.spaces[id: from]!.takeFolder(id)
        // Web contents belong to a profile, so the tabs reload in a space with another one.
        let unloaded = target.profileID == source.profileID ? [] : rows.compactMap { row -> Tab.ID? in
          guard case let .tab(tab) = row, tab.isLive else { return nil }
          return tab.id
        }
        rows = rows.map {
          guard case var .tab(tab) = $0, unloaded.contains(tab.id) else { return $0 }
          tab.isLive = false
          tab.isLoading = false
          return .tab(tab)
        }
        state.spaces[id: to]?.add(rows, from: source.folders[id: id]!.placement)
        return .merge(
          .run { _ in for tab in unloaded { await engine.close(tab) } },
          .send(.spaces(.element(id: from, action: .activate))),
          unloaded.isEmpty ? .none : .send(.delegate(.movedAcrossProfiles))
        )

      case let .moveSpace(id, index):
        guard let space = state.spaces.remove(id: id) else { return .none }
        state.spaces.insert(space, at: min(max(index, 0), state.spaces.count))
        return .none

      case let .moveTab(id, from, to):
        guard
          from != to, let target = state.spaces[id: to], let source = state.spaces[id: from], var tab = source.tabs[id: id],
          tab.placement != .favorite || target.profileID != source.profileID
        else { return .none }
        state.spaces[id: from]?.tabs.remove(id: id)
        state.spaces[id: from]?.selection.remove(id)
        if case .folder = tab.placement {
          tab.placement = .pinned
        }
        // A group belongs to its space.
        tab.groupID = nil
        // Web contents belong to a profile, so the tab reloads in a space with another one.
        let reloads = tab.isLive && target.profileID != source.profileID
        if reloads {
          tab.isLive = false
          tab.isLoading = false
        }
        state.spaces[id: to]?.tabs.insert(tab, at: 0)
        if tab.placement == .pinned {
          state.spaces[id: to]?.pinnedOrder.insert(id, at: 0)
        }
        let close: Effect<Action> = reloads
          ? .merge(.run { _ in await engine.close(id) }, .send(.delegate(.movedAcrossProfiles))) : .none
        // Every space that showed the tab and lost it (a favorite leaves every space of its profile) shows its
        // most recently active tab instead.
        return .merge([close] + state.spaces.filter { $0.id != to && $0.selectedTabID == id && $0.tabs[id: id] == nil }.map { space in
          state.spaces[id: space.id]?.selectedTabID = space.tabs.max { $0.lastActiveAt < $1.lastActiveAt }?.id
          return state.selectedID == space.id ? .send(.spaces(.element(id: space.id, action: .activate))) : .none
        })

      case let .copyTab(id, from, to, placement, before):
        guard from != to, var target = state.spaces[id: to], let tab = state.spaces[id: from]?.tabs[id: id] else { return .none }
        var copy = Tab(
          id: uuid(), url: tab.url, title: tab.title, placement: placement ?? tab.placement, pinnedURL: tab.pinnedURL,
          customTitle: tab.customTitle, icon: tab.icon, createdAt: now, lastActiveAt: now, favicon: tab.favicon)
        // A folder tab dropped on the dot lands pinned; a favorite copies into Today; Today tabs keep no pinned URL.
        if placement == nil, case .folder = copy.placement {
          copy.placement = .pinned
        }
        if copy.placement == .favorite {
          copy.placement = .unpinned
        }
        copy.pinnedURL = copy.placement == .unpinned ? nil : copy.pinnedURL ?? copy.url
        // As TabsFeature's duplicate places a copy: before the row, or at the end of the placement.
        let index = placement == nil ? 0 : before.flatMap { target.tabs.index(id: $0) } ?? target.tabs.endIndex
        target.tabs.insert(copy, at: index)
        if copy.placement.isPinnedSection {
          target.place(copy.id, before: placement == nil ? target.tree().first?.id : before)
        }
        state.spaces[id: to] = target
        return .none

      case let .restore(space, index):
        guard state.spaces[id: space.id] == nil else { return .none }
        @Shared(.archive) var archive
        $archive.withLock { $0.removeAll { item in space.ownTabs[id: item.id] != nil } }
        state.spaces.insert(space, at: min(index, state.spaces.count))
        return select(space.id, &state)

      case let .select(id):
        guard state.spaces[id: id] != nil else { return .none }
        return select(id, &state)

      case let .setProfile(id, profile):
        guard let space = state.spaces[id: id], space.profileID != profile else { return .none }
        state.spaces[id: id]?.profileID = profile
        // The space shows the other profile's favorites from here on; the old ones stay with theirs, so one that
        // was shown gives way to the most recently active own tab.
        let live = space.ownTabs.filter(\.isLive).map(\.id)
        for tab in live {
          state.spaces[id: id]?.ownTabs[id: tab]?.isLive = false
          state.spaces[id: id]?.ownTabs[id: tab]?.isLoading = false
        }
        if let selected = space.selectedTabID, state.spaces[id: id]?.tabs[id: selected] == nil {
          state.spaces[id: id]?.selectedTabID = space.ownTabs.max { $0.lastActiveAt < $1.lastActiveAt }?.id
        }
        // The old web contents close before the selected tab loads again in the new profile.
        return .concatenate(
          .run { _ in for tab in live { await engine.close(tab) } },
          state.selectedID == id ? .send(.spaces(.element(id: id, action: .activate))) : .none
        )

      case .spaces:
        return .none

      case let .update(id, name, icon, theme):
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let old = state.spaces[id: id] else { return .none }
        state.spaces[id: id]?.name = name
        state.spaces[id: id]?.icon = icon
        state.spaces[id: id]?.theme = theme
        let edit = SpaceEdit(name: old.name, icon: old.icon, theme: old.theme)
        return edit == SpaceEdit(name: name, icon: icon, theme: theme) ? .none : .send(.delegate(.edited(id, edit)))

      case let .revert(id, edit):
        state.spaces[id: id]?.name = edit.name
        state.spaces[id: id]?.icon = edit.icon
        state.spaces[id: id]?.theme = edit.theme
        return .none
      }
    }
    .forEach(\.spaces, action: \.spaces) {
      TabsFeature()
    }
  }

  private func select(_ id: Space.ID, _ state: inout State) -> Effect<Action> {
    let previous = state.selectedID
    state.selectedID = id
    // A multi-selection belongs to the moment; a space switch ends it.
    state.spaces[id: previous]?.selection = []
    // A page the previous switch put off is not wanted once its space is left.
    return .merge(
      previous == id ? .none : .cancel(id: TabsFeature.PendingActivation(space: previous)),
      .send(.spaces(.element(id: id, action: .activateAfterSwitch)))
    )
  }
}
