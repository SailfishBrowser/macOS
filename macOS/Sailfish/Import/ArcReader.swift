import AppKit
import Foundation

// What an Arc data folder holds that this browser takes: its spaces with their pinned rows and Today tabs, each
// profile's favorites, the archive and the shortcuts the user changed. macOS/scripts/arc-import/dump_sidebar.py
// describes the files. ZenReader makes one of a Zen profile.
struct ArcData: Equatable, Sendable {
  struct Tab: Equatable, Sendable {
    var url: URL
    var title: String
    var customTitle: String?
    var icon: String?
    var createdAt: Date
  }

  indirect enum Row: Equatable, Sendable {
    case tab(Tab)
    case folder(name: String, rows: [Row])
  }

  struct Space: Equatable, Sendable {
    var name: String
    var icon: String
    // The Arc profile's name; nil is Default.
    var profile: String?
    var pinned: [Row]
    var today: [Tab]
    // Zen's; Arc's spaces have the default.
    var theme = SpaceTheme()
  }

  struct Favorites: Equatable, Sendable {
    var profile: String?
    var tabs: [Tab]
  }

  struct Archived: Equatable, Sendable {
    var url: URL
    var title: String
    var archivedAt: Date
    var profile: String?
  }

  // A shortcut the user changed: its new keys, removed, or keys this browser cannot take.
  struct Shortcut: Equatable, Sendable {
    enum Keys: Equatable, Sendable {
      case keys(KeyBinding)
      case removed
      case unsupported(String)
    }
    var name: String
    var keys: Keys
  }

  var spaces: [Space] = []
  var favorites: [Favorites] = []
  // Newest first.
  var archive: [Archived] = []
  var shortcuts: [Shortcut] = []
  // Zen's, as pinned rows of a space of their own.
  var bookmarks: Space?
}

enum ArcImportError: Error, Equatable {
  case notFound
  case unreadable
}

enum ArcReader {
  static func defaultFolder(home: URL) -> URL {
    home.appending(path: "Library/Application Support/Arc")
  }

  static func read(_ folder: URL) throws -> ArcData {
    let sidebarFile = folder.appending(path: "StorableSidebar.json")
    guard FileManager.default.fileExists(atPath: sidebarFile.path) else { throw ArcImportError.notFound }
    do {
      let decoder = JSONDecoder()
      let sidebar = try decoder.decode(SidebarFile.self, from: Data(contentsOf: sidebarFile))
      guard let container = sidebar.sidebar.containers.first(where: { $0.spaces != nil }) else {
        throw ArcImportError.unreadable
      }
      let names = profileNames(folder)
      func name(_ profile: ProfileKey) -> String? {
        profile.directory.map { names[$0] ?? $0 }
      }
      let items = Dictionary(container.items?.pairs ?? []) { $1 }
      let spaces = container.spaces?.pairs ?? []
      var data = ArcData()
      for (index, (_, space)) in spaces.enumerated() {
        let roles = Dictionary(stride(from: 0, to: space.containerIDs.count - 1, by: 2).map {
          (space.containerIDs[$0], space.containerIDs[$0 + 1])
        }) { $1 }
        let children = { (role: String) in roles[role].flatMap { items[$0]?.childrenIds } ?? [] }
        data.spaces.append(ArcData.Space(
          name: space.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Space \(index + 1)", icon: space.customInfo?.iconType?.spaceIcon ?? "",
          profile: name(space.profile), pinned: try rows(children("pinned"), items),
          today: try tabs(children("unpinned"), items)))
      }
      data.favorites = try (container.topAppsContainerIDs?.pairs ?? []).map { profile, id in
        ArcData.Favorites(profile: name(profile), tabs: try tabs(items[id]?.childrenIds ?? [], items))
      }
      let spaceProfiles = Dictionary(spaces.map { ($0.0, name($0.1.profile)) }) { $1 }
      let archiveFile = folder.appending(path: "StorableArchiveItems.json")
      if FileManager.default.fileExists(atPath: archiveFile.path) {
        let archive = try decoder.decode(ArchiveFile.self, from: Data(contentsOf: archiveFile))
        data.archive = archive.items.pairs.compactMap { _, entry in
          guard let tab = tab(entry.sidebarItem) else { return nil }
          return ArcData.Archived(
            url: tab.url, title: tab.customTitle ?? tab.title,
            archivedAt: Date(timeIntervalSinceReferenceDate: entry.archivedAt),
            profile: entry.source.space.flatMap { spaceProfiles[$0._0] ?? nil })
        }
        .sorted { $0.archivedAt > $1.archivedAt }
      }
      let bindingsFile = folder.appending(path: "StorableKeyBindings.json")
      if FileManager.default.fileExists(atPath: bindingsFile.path) {
        let bindings = try decoder.decode(KeyBindingsFile.self, from: Data(contentsOf: bindingsFile))
        data.shortcuts = bindings.userOverrides.map { override in
          ArcData.Shortcut(name: override.action.name, keys: override.state.valid.map { keys($0._0) } ?? .removed)
        }
      }
      return data
    } catch let error as ArcImportError {
      throw error
    } catch {
      throw ArcImportError.unreadable
    }
  }

  // Folders and tabs in order; a split view's tabs stand in its place, one after another. An item inside itself
  // makes the file unreadable.
  private static func rows(_ ids: [String], _ items: [String: Item], within: Set<String> = []) throws -> [ArcData.Row] {
    try ids.flatMap { id -> [ArcData.Row] in
      guard let item = items[id] else { return [] }
      guard !within.contains(id) else { throw ArcImportError.unreadable }
      let children = try rows(item.childrenIds, items, within: within.union([id]))
      if item.data.list != nil {
        return [.folder(name: item.title ?? "Untitled", rows: children)]
      }
      if item.data.splitView != nil {
        return children.filter { if case .tab = $0 { true } else { false } }
      }
      return tab(item).map { [.tab($0)] } ?? []
    }
  }

  private static func tabs(_ ids: [String], _ items: [String: Item]) throws -> [ArcData.Tab] {
    try rows(ids, items).compactMap { if case let .tab(tab) = $0 { tab } else { nil } }
  }

  private static func tab(_ item: Item) -> ArcData.Tab? {
    // An archived tab that never loaded has no URL.
    guard let tab = item.data.tab, let url = tab.savedURL.flatMap(URL.init(string:)), url.scheme != nil else { return nil }
    return ArcData.Tab(
      url: url, title: tab.savedTitle ?? url.absoluteString, customTitle: item.title, icon: tab.customInfo?.iconType?.emoji,
      createdAt: Date(timeIntervalSinceReferenceDate: item.createdAt))
  }

  // Arc writes special keys as their glyphs.
  private static let specialKeys: [Character: Int] = [
    "⇥": 0x09, "↑": NSUpArrowFunctionKey, "↓": NSDownArrowFunctionKey, "←": NSLeftArrowFunctionKey,
    "→": NSRightArrowFunctionKey,
  ]

  private static func keys(_ shortcut: ShortcutKeys) -> ArcData.Shortcut.Keys {
    let glyph = shortcut.keyEquivalent
    guard glyph.count == 1 else { return .unsupported(glyph) }
    let key = specialKeys[glyph.first!].map { String(UnicodeScalar(UInt16($0))!) } ?? glyph
    guard specialKeys[glyph.first!] != nil || glyph.unicodeScalars.allSatisfy(\.isASCII) else { return .unsupported(glyph) }
    let modifiers = NSEvent.ModifierFlags(rawValue: shortcut.deviceIndependentModifierFlags)
      .intersection([.command, .control, .option, .shift])
    return .keys(KeyBinding(key: key, modifiers: modifiers).normalized)
  }

  // Profile names by directory, from the Chromium profile's Local State.
  private static func profileNames(_ folder: URL) -> [String: String] {
    struct LocalState: Decodable {
      struct Profiles: Decodable { let info_cache: [String: Info] }
      struct Info: Decodable { let name: String }
      let profile: Profiles
    }
    let file = folder.appending(path: "User Data/Local State")
    guard let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(LocalState.self, from: data)
    else { return [:] }
    return state.profile.info_cache.mapValues(\.name)
  }
}

// Swift's Codable form of a dictionary: keys and values alternating in one list.
private struct Pairs<Key: Decodable, Value: Decodable>: Decodable {
  var pairs: [(Key, Value)] = []

  init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    while !container.isAtEnd {
      pairs.append((try container.decode(Key.self), try container.decode(Value.self)))
    }
  }
}

// An enum case's associated value.
private struct Associated<Value: Decodable>: Decodable {
  let _0: Value
}

private struct Empty: Decodable {}

// {"default": ...} or {"custom": {"_0": {"directoryBasename": ..., "machineID": ...}}}.
private struct ProfileKey: Decodable {
  struct Custom: Decodable { let directoryBasename: String }
  let custom: Associated<Custom>?

  var directory: String? { custom?._0.directoryBasename }
}

private struct CustomInfo: Decodable {
  struct IconType: Decodable {
    let emoji_v2: String?
    // One of Arc's own symbols, as "planet", which marks its primary space.
    let icon: String?

    var emoji: String? { emoji_v2 }
    var spaceIcon: String? { icon == "planet" ? Space.primaryIcon : emoji }
  }
  let iconType: IconType?
}

private struct Item: Decodable {
  struct ItemData: Decodable {
    struct TabData: Decodable {
      let savedURL: String?
      let savedTitle: String?
      let customInfo: CustomInfo?
    }
    let tab: TabData?
    let list: Empty?
    let splitView: Empty?
  }
  let title: String?
  let createdAt: Double
  let childrenIds: [String]
  let data: ItemData
}

private struct SidebarFile: Decodable {
  struct Body: Decodable { let containers: [Container] }
  struct Container: Decodable {
    let items: Pairs<String, Item>?
    let spaces: Pairs<String, Space>?
    let topAppsContainerIDs: Pairs<ProfileKey, String>?
  }
  struct Space: Decodable {
    let title: String?
    let profile: ProfileKey
    // Roles and container ids alternating: "pinned", id, "unpinned", id.
    let containerIDs: [String]
    let customInfo: CustomInfo?
  }
  let sidebar: Body
}

private struct ArchiveFile: Decodable {
  struct Entry: Decodable {
    struct Source: Decodable { let space: Associated<String>? }
    let sidebarItem: Item
    let archivedAt: Double
    let source: Source
  }
  let items: Pairs<String, Entry>
}

private struct ShortcutKeys: Decodable {
  let keyEquivalent: String
  let deviceIndependentModifierFlags: UInt
}

private struct KeyBindingsFile: Decodable {
  struct Override: Decodable {
    struct Action: Decodable { let name: String }
    struct State: Decodable { let valid: Associated<ShortcutKeys>? }
    let action: Action
    let state: State
  }
  let userOverrides: [Override]
}
