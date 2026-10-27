import Foundation

// A row of the pinned section or of a folder: folders and pinned tabs mix in any order, and nests folders.
enum PinnedRow: Equatable, Identifiable {
  case tab(Tab)
  case folder(Folder)

  var id: UUID {
    switch self {
    case let .tab(tab): tab.id
    case let .folder(folder): folder.id
    }
  }

  var placement: Placement {
    switch self {
    case let .tab(tab): tab.placement
    case let .folder(folder): folder.placement
    }
  }
}

extension Placement {
  var isPinnedSection: Bool {
    switch self {
    case .pinned, .folder: true
    case .favorite, .unpinned: false
    }
  }
}

extension TabsFeature.State {
  // The container's rows in pinnedOrder. Rows it doesn't list yet follow, folders first.
  func rows(in container: Placement) -> [PinnedRow] {
    let rows = folders.filter { $0.placement == container }.map(PinnedRow.folder) + tabs(in: container).map(PinnedRow.tab)
    let position = Dictionary(pinnedOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
    return rows.enumerated()
      .sorted { (position[$0.element.id] ?? .max, $0.offset) < (position[$1.element.id] ?? .max, $1.offset) }
      .map(\.element)
  }

  // The tabs of a placement in sidebar order.
  func orderedTabs(in placement: Placement) -> [Tab] {
    if placement == .favorite { return favoriteGrid.flatMap { $0 } }
    guard placement.isPinnedSection else { return tabs(in: placement) }
    return rows(in: placement).compactMap { if case let .tab(tab) = $0 { tab } else { nil } }
  }

  // The rows under a container, depth first, as the sidebar lists them.
  func tree(_ container: Placement = .pinned) -> [PinnedRow] {
    rows(in: container).flatMap { row in
      if case let .folder(folder) = row { [row] + tree(.folder(folder.id)) } else { [row] }
    }
  }

  // Whether the folder is the other one or inside it.
  func folder(_ id: Folder.ID, isWithin other: Folder.ID) -> Bool {
    var current = Optional(id)
    while let folder = current {
      if folder == other { return true }
      guard case let .folder(parent) = folders[id: folder]?.placement else { return false }
      current = parent
    }
    return false
  }

  // Orders a pinned-section row before another row of its container, or last in it.
  mutating func place(_ id: UUID, before: UUID?) {
    var order = tree().map(\.id).filter { $0 != id }
    order.insert(id, at: before.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
    pinnedOrder = order
  }
}

extension TabsFeature.State {
  // Takes the folder and everything in it out of the space, in sidebar order.
  mutating func takeFolder(_ id: Folder.ID) -> [PinnedRow] {
    guard let folder = folders[id: id] else { return [] }
    let rows = [PinnedRow.folder(folder)] + tree(.folder(id))
    for row in rows {
      switch row {
      case let .folder(folder): folders.remove(id: folder.id)
      case let .tab(tab):
        tabs.remove(id: tab.id)
        selection.remove(tab.id)
      }
    }
    if let selected = selectedTabID, tabs[id: selected] == nil {
      selectedTabID = tabs.max { $0.lastActiveAt < $1.lastActiveAt }?.id
    }
    return rows
  }

  // Adds rows taken from a space at the top of the pinned section; rows in `parent` move to the pinned section.
  mutating func add(_ rows: [PinnedRow], from parent: Placement) {
    add(rows.map { row in
      switch row {
      case var .folder(folder):
        folder.placement = folder.placement == parent ? .pinned : folder.placement
        return .folder(folder)
      case var .tab(tab):
        tab.placement = tab.placement == parent ? .pinned : tab.placement
        return .tab(tab)
      }
    })
  }

  // Adds rows, placed as they are, at the top of the pinned section.
  mutating func add(_ rows: [PinnedRow]) {
    let order = rows.map(\.id) + tree().map(\.id)
    for row in rows {
      switch row {
      case let .folder(folder): folders.append(folder)
      case let .tab(tab): tabs.append(tab)
      }
    }
    pinnedOrder = order
  }
}

extension TabsFeature.State {
  // The "Recently recovered" folder: the Today tabs of a state read from a backup, gathered at the end of the
  // pinned section so they stand out from what the sidebar held.
  mutating func gatherRecovered(into id: Folder.ID) {
    let today = tabs(in: .unpinned)
    guard !today.isEmpty else { return }
    folders.append(Folder(id: id, name: "Recently recovered", placement: .pinned))
    place(id, before: nil)
    for tab in today {
      tabs[id: tab.id]?.placement = .folder(id)
      tabs[id: tab.id]?.pinnedURL = tab.url
      place(tab.id, before: nil)
    }
  }
}
