import AppKit
import ComposableArchitecture
import Foundation

// Arc's changed shortcuts as this browser's: the keys by Shortcuts row, and Arc's names of those left out.
struct ArcShortcuts: Equatable, Sendable {
  var bindings: [String: KeyBinding] = [:]
  var skipped: [String] = []
}

extension ArcShortcuts {
  // Arc's names of commands titled otherwise in this menu bar.
  private static let titles = ["Tab Switcher (forward)": "Cycle Tab Forward", "Tab Switcher (backward)": "Cycle Tab Backward"]

  // Each shortcut goes to the menu row of its name. One whose keys another row would keep is left out, as the
  // Shortcuts pane refuses them.
  @MainActor
  init(_ shortcuts: [ArcData.Shortcut], menu: NSMenu, current: [String: KeyBinding]) {
    let owners = MenuShortcuts.owners(in: menu)
    func plain(_ title: String) -> String {
      (title.hasSuffix("…") ? String(title.dropLast()) : title).lowercased()
    }
    let rows = Dictionary(owners.map { (plain($0.key), $0.value) }) { first, _ in first }
    var names: [String: String] = [:]
    for shortcut in shortcuts {
      guard let id = rows[plain(Self.titles[shortcut.name] ?? shortcut.name)] else {
        skipped.append("\(shortcut.name) (no such command)")
        continue
      }
      switch shortcut.keys {
      case let .keys(keys):
        bindings[id] = keys
        names[id] = shortcut.name
      case .removed:
        bindings[id] = KeyBinding(key: "", modifiers: [])
      case let .unsupported(glyph):
        skipped.append("\(shortcut.name) (key \(glyph))")
      }
    }
    func owner(_ item: NSMenuItem) -> String? {
      MenuShortcuts.row(item).flatMap { owners[$0] }
    }
    let imported = bindings
    func keys(_ item: NSMenuItem) -> KeyBinding {
      owner(item).flatMap { imported[$0] ?? current[$0] }
        ?? MenuShortcuts.id(item).flatMap { MenuShortcuts.defaults[$0] } ?? KeyBinding(item)
    }
    let items = MenuShortcuts.items(in: menu)
    for (id, binding) in imported where !binding.key.isEmpty {
      guard
        let taken = items.first(where: { owner($0) != id && !keys($0).key.isEmpty && keys($0).normalized == binding })
      else { continue }
      bindings[id] = nil
      skipped.append("\(names[id]!) (keys of \(taken.title))")
    }
    skipped.sort()
  }
}

// What an import added and the shortcuts it changed, so that undo can take it out again.
struct ArcImportRecord: Equatable {
  struct ShortcutChange: Equatable {
    let before: KeyBinding?
    let after: KeyBinding
  }
  // The space shown when the import ran.
  var shown: Space.ID
  var spaces: [Space.ID] = []
  // The tabs it put in those spaces.
  var tabs: Set<Tab.ID> = []
  var profiles: [Profile.ID] = []
  var favorites: [Tab.ID] = []
  var archive: [ArchivedTab.ID] = []
  // By Shortcuts row.
  var shortcuts: [String: ShortcutChange] = [:]
}

@DependencyClient
struct ArcImportClient: Sendable {
  var defaultFolder: @Sendable () -> URL = { URL(filePath: NSHomeDirectory()) }
  var read: @Sendable (_ folder: URL) async throws -> ArcData
  var shortcuts: @Sendable (_ shortcuts: [ArcData.Shortcut]) async -> ArcShortcuts = { _ in ArcShortcuts() }
  // Puts the saved shortcuts on the menu bar.
  var applyShortcuts: @Sendable () async -> Void
}

extension ArcImportClient: TestDependencyKey {
  static let testValue = Self()
}

extension DependencyValues {
  var arcImport: ArcImportClient {
    get { self[ArcImportClient.self] }
    set { self[ArcImportClient.self] = newValue }
  }
}

extension ArcImportClient: DependencyKey {
  static let liveValue = Self(
    defaultFolder: { ArcReader.defaultFolder(home: .homeDirectory) },
    read: { folder in try await Task.detached { try ArcReader.read(folder) }.value },
    shortcuts: { shortcuts in
      await MainActor.run {
        @Shared(.keyBindings) var current
        return ArcShortcuts(shortcuts, menu: NSApp.mainMenu!, current: current)
      }
    },
    applyShortcuts: { await MainActor.run { NSApp.mainMenu.map(MenuShortcuts.apply) } }
  )
}

@Reducer
struct ArcImportFeature {
  enum Category: CaseIterable, Hashable, Sendable {
    case spaces, pinnedTabs, todayTabs, favorites, shortcuts, archive, history, passwords, cookies
  }

  // Archived tabs taken, the newest: as many as the archive keeps histories for.
  static let archiveLimit = AppFeature.State.archivedSessions

  @ObservableState
  struct State: Equatable {
    var folder: URL
    var data: ArcData?
    var shortcuts = ArcShortcuts()
    var failure: ArcImportError?
    var included = Set(Category.allCases)

    // Pinned and Today tabs come with their spaces.
    func isAvailable(_ category: Category) -> Bool {
      category != .pinnedTabs && category != .todayTabs || included.contains(.spaces)
    }

    func isIncluded(_ category: Category) -> Bool {
      isAvailable(category) && included.contains(category)
    }
  }

  enum Action {
    case appeared
    case cancelTapped
    case delegate(Delegate)
    case folderChosen(URL)
    case importTapped
    case loaded(Result<ArcData, ArcImportError>, ArcShortcuts)
    case toggled(Category, Bool)

    @CasePathable
    enum Delegate {
      case cancel
      case `import`(ArcData, ArcShortcuts, Set<Category>)
    }
  }

  @Dependency(\.arcImport) var arcImport

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appeared:
        return load(state.folder)

      case .cancelTapped:
        return .send(.delegate(.cancel))

      case .delegate:
        return .none

      case let .folderChosen(folder):
        state.folder = folder
        state.data = nil
        state.failure = nil
        return load(folder)

      case .importTapped:
        guard let data = state.data else { return .none }
        let included = Set(Category.allCases.filter(state.isIncluded))
        return .send(.delegate(.import(data, state.shortcuts, included)))

      case let .loaded(.success(data), shortcuts):
        state.data = data
        state.shortcuts = shortcuts
        return .none

      case let .loaded(.failure(failure), _):
        state.failure = failure
        return .none

      case let .toggled(category, isOn):
        if isOn {
          state.included.insert(category)
        } else {
          state.included.remove(category)
        }
        return .none
      }
    }
  }

  private func load(_ folder: URL) -> Effect<Action> {
    .run { send in
      do {
        let data = try await arcImport.read(folder)
        await send(.loaded(.success(data), await arcImport.shortcuts(data.shortcuts)))
      } catch {
        await send(.loaded(.failure(error as? ArcImportError ?? .unreadable), ArcShortcuts()))
      }
    }
  }
}

extension ArcImportFeature {
  // The archived tabs an import may add: those the archive keeps histories for are its own, so imported ones,
  // which have none, only fill what is left below that count.
  static var archiveRoom: Int {
    @Shared(.archive) var archive
    return max(archiveLimit - archive.count, 0)
  }

  // Adds what was chosen to the current state: Arc's profiles by name (its Default is the first profile), its
  // spaces after the window's, favorites the profile lacks by page, the newest archived tabs that fit and the
  // shortcuts. The pages stay unloaded until opened.
  static func merge(
    _ data: ArcData, _ shortcuts: ArcShortcuts, _ included: Set<Category>, into spaces: inout SpacesFeature.State,
    uuid: UUIDGenerator, now: Date
  ) -> ArcImportRecord {
    @Shared(.profiles) var profiles
    @Shared(.archive) var archive
    @Shared(.keyBindings) var keyBindings
    var record = ArcImportRecord(shown: spaces.selectedID)
    func profile(_ name: String?) -> Profile.ID {
      guard let name else { return profiles[0].id }
      if let existing = profiles.first(where: { $0.name == name }) { return existing.id }
      let profile = Profile(id: uuid(), name: name)
      $profiles.withLock { _ = $0.append(profile) }
      record.profiles.append(profile.id)
      return profile.id
    }
    func tab(_ tab: ArcData.Tab, _ placement: Placement) -> Tab {
      Tab(
        id: uuid(), url: tab.url, title: tab.title, placement: placement,
        pinnedURL: placement == .unpinned ? nil : tab.url, customTitle: tab.customTitle, icon: tab.icon,
        createdAt: tab.createdAt, lastActiveAt: now)
    }
    func add(_ rows: [ArcData.Row], to container: Placement, in space: inout Space) {
      for row in rows {
        switch row {
        case let .tab(arc):
          let tab = tab(arc, container)
          space.ownTabs.append(tab)
          space.pinnedOrder.append(tab.id)
        case let .folder(name, rows):
          let folder = Folder(id: uuid(), name: name, placement: container)
          space.folders.append(folder)
          space.pinnedOrder.append(folder.id)
          add(rows, to: .folder(folder.id), in: &space)
        }
      }
    }

    if included.contains(.spaces) {
      for arc in data.spaces {
        var space = Space(id: uuid(), name: arc.name, profileID: profile(arc.profile), createdAt: now, icon: arc.icon)
        if included.contains(.pinnedTabs) {
          add(arc.pinned, to: .pinned, in: &space)
        }
        if included.contains(.todayTabs) {
          space.ownTabs.append(contentsOf: arc.today.map { tab($0, .unpinned) })
        }
        spaces.spaces.append(space)
        record.spaces.append(space.id)
        record.tabs.formUnion(space.ownTabs.ids)
      }
    }
    if included.contains(.favorites) {
      for group in data.favorites where !group.tabs.isEmpty {
        let id = profile(group.profile)
        var pages = profiles[id: id]!.favorites.map { $0.pinnedURL ?? $0.url }
        var added: [Tab] = []
        for arc in group.tabs where !pages.contains(where: { $0.isSamePage(as: arc.url) }) {
          pages.append(arc.url)
          added.append(tab(arc, .favorite))
        }
        $profiles.withLock { $0[id: id]!.favorites.append(contentsOf: added) }
        record.favorites += added.map(\.id)
      }
    }
    if included.contains(.archive) {
      struct Key: Hashable {
        let url: URL
        let archivedAt: Date
      }
      let existing = Set(archive.map { Key(url: $0.url, archivedAt: $0.archivedAt) })
      let added = data.archive.filter { !existing.contains(Key(url: $0.url, archivedAt: $0.archivedAt)) }.prefix(archiveRoom)
        .map { ArchivedTab(id: uuid(), url: $0.url, title: $0.title, profileID: profile($0.profile), archivedAt: $0.archivedAt) }
      $archive.withLock { $0 = IdentifiedArray(uniqueElements: ($0.elements + added).sorted { $0.archivedAt > $1.archivedAt }) }
      record.archive = added.map(\.id)
    }
    if included.contains(.shortcuts) {
      for (id, binding) in shortcuts.bindings where keyBindings[id] != binding {
        record.shortcuts[id] = ArcImportRecord.ShortcutChange(before: keyBindings[id], after: binding)
      }
      $keyBindings.withLock { $0.merge(shortcuts.bindings) { $1 } }
    }
    return record
  }

  // Takes out what the import added that is still there, but never a window's last spaces. Tabs added to its spaces
  // since go to the archive, as when a space is deleted, and a shortcut changed since stays. Returns the pages to
  // close; the profiles it added are for the app to remove where no space uses them.
  static func revert(_ record: ArcImportRecord, in spaces: inout SpacesFeature.State, now: Date) -> [Tab.ID] {
    @Shared(.profiles) var profiles
    @Shared(.archive) var archive
    @Shared(.keyBindings) var keyBindings
    let imported = Set(record.spaces)
    var closed: [Tab.ID] = []
    if spaces.spaces.contains(where: { !imported.contains($0.id) }) {
      let removed = spaces.spaces.filter { imported.contains($0.id) }
      closed += removed.flatMap { $0.ownTabs.filter(\.isLive).map(\.id) }
      let kept = removed.flatMap { space in
        space.ownTabs.filter { !record.tabs.contains($0.id) }.map {
          ArchivedTab(id: $0.id, url: $0.url, title: $0.displayTitle, profileID: space.profileID, archivedAt: now)
        }
      }
      $archive.withLock { $0.insert(contentsOf: kept, at: 0) }
      spaces.spaces.removeAll { imported.contains($0.id) }
      if spaces.spaces[id: spaces.selectedID] == nil || spaces.spaces[id: record.shown] != nil {
        spaces.selectedID = spaces.spaces[id: record.shown]?.id ?? spaces.spaces[0].id
      }
    }
    let favorites = Set(record.favorites)
    closed += profiles.flatMap { $0.favorites.filter { favorites.contains($0.id) && $0.isLive }.map(\.id) }
    $profiles.withLock { profiles in
      for id in profiles.ids {
        profiles[id: id]!.favorites.removeAll { favorites.contains($0.id) }
        profiles[id: id]!.favoriteRows = profiles[id: id]!.favoriteRows.map { $0.filter { !favorites.contains($0) } }
          .filter { !$0.isEmpty }
      }
    }
    // A space that showed a removed favorite shows its most recently active own tab.
    for space in spaces.spaces where space.selectedTabID.map({ favorites.contains($0) }) == true {
      spaces.spaces[id: space.id]!.selectedTabID = space.ownTabs.max { $0.lastActiveAt < $1.lastActiveAt }?.id
    }
    let archived = Set(record.archive)
    $archive.withLock { $0.removeAll { archived.contains($0.id) } }
    $keyBindings.withLock { bindings in
      for (id, change) in record.shortcuts where bindings[id] == change.after {
        bindings[id] = change.before
      }
    }
    return closed
  }
}
