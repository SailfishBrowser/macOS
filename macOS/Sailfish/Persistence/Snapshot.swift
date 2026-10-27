import ComposableArchitecture
import Foundation

struct Snapshot: Codable, Equatable {
  typealias Migration = @Sendable (inout [String: Any]) throws -> Void

  static let version = 13
  static let migrations: [Int: Migration] = [
    // Adds the profile list, one profile per distinct space profile, and each space's icon and theme.
    1: { json in
      var profiles: [String] = []
      try eachSpace(&json) { space in
        space["icon"] = ""
        space["theme"] = [UInt32]()
        if let profile = space["profileID"] as? String, !profiles.contains(profile) {
          profiles.append(profile)
        }
      }
      json["profiles"] = profiles.enumerated().map { ["id": $1, "name": $0 == 0 ? "Default" : "Profile \($0 + 1)"] }
    },
    // Adds grain and intensity to each space's theme colors.
    2: { json in
      try eachSpace(&json) { space in
        space["theme"] = ["colors": space["theme"]!, "grain": 0, "intensity": SpaceTheme().intensity]
      }
    },
    // Gives every pinned tab, favorite and folder tab a pinned URL: the one it shows.
    3: { json in
      try eachSpace(&json) { space in
        var tabs = space["tabs"] as! [[String: Any]]
        for tab in tabs.indices where (tabs[tab]["placement"] as! [String: Any])["unpinned"] == nil {
          tabs[tab]["pinnedURL"] = tabs[tab]["url"]
        }
        space["tabs"] = tabs
      }
    },
    // Adds the archive and each profile's "Archive tabs after".
    4: { json in
      json["archive"] = [Any]()
      json["profiles"] = (json["profiles"] as! [[String: Any]]).map { $0.merging(["archiveAfter": 12 * 3600]) { $1 } }
    },
    // Adds each space's split views.
    5: { json in
      try eachSpace(&json) { space in
        space["splits"] = [Any]()
      }
    },
    // Puts each folder in the pinned section and adds the pinned section's order.
    6: { json in
      try eachSpace(&json) { space in
        space["folders"] = (space["folders"] as! [[String: Any]]).map { $0.merging(["placement": ["pinned": [:]]]) { $1 } }
        space["pinnedOrder"] = [String]()
      }
    },
    // Adds whether each space's pinned section is collapsed.
    7: { json in
      try eachSpace(&json) { space in
        space["isPinnedCollapsed"] = false
      }
    },
    // Lays each space's favorites out in rows: as few as fit three to a row, filled evenly.
    8: { json in
      try eachSpace(&json) { space in
        let favorites = (space["tabs"] as! [[String: Any]]).filter { ($0["placement"] as! [String: Any])["favorite"] != nil }
        let rows = max((favorites.count + 2) / 3, 1)
        let perRow = max((favorites.count + rows - 1) / rows, 1)
        space["favoriteRows"] = stride(from: 0, to: favorites.count, by: perRow).map {
          favorites[$0..<min($0 + perRow, favorites.count)].map { $0["id"]! }
        }
      }
    },
    // Adds whether each space's name heading is hidden.
    9: { json in
      try eachSpace(&json) { space in
        space["isHeaderHidden"] = false
      }
    },
    // Moves favorites to their profile, as they belong to it: a profile's favorites are those of its spaces in
    // space order, one per pinned URL, and their rows follow. A space showing a dropped duplicate shows the kept one,
    // and a space whose profile is missing (such a space goes back to the first profile when loaded) gives its
    // favorites to the first profile.
    10: { json in
      let profiles = json["profiles"] as! [[String: Any]]
      let known = Set(profiles.map { $0["id"] as! String })
      var favorites: [String: [[String: Any]]] = [:]
      var rows: [String: [[String]]] = [:]
      // Each profile's kept favorite by pinned URL, and the ids its rows already hold.
      var kept: [String: [String: String]] = [:]
      var placed: Set<String> = []
      try eachSpace(&json) { space in
        var profile = space["profileID"] as! String
        if !known.contains(profile), let first = profiles.first {
          profile = first["id"] as! String
        }
        let tabs = space["tabs"] as! [[String: Any]]
        space["tabs"] = tabs.filter { ($0["placement"] as! [String: Any])["favorite"] == nil }
        // The space's favorite ids, each mapped to the kept favorite of its URL.
        var ids: [String: String] = [:]
        for tab in tabs where (tab["placement"] as! [String: Any])["favorite"] != nil {
          let url = tab["pinnedURL"] as? String ?? tab["url"] as! String
          if kept[profile]?[url] == nil {
            favorites[profile, default: []].append(tab)
            kept[profile, default: [:]][url] = tab["id"] as? String
          }
          ids[tab["id"] as! String] = kept[profile]![url]
        }
        for row in space["favoriteRows"] as! [[String]] {
          let row = row.compactMap { ids[$0] }.filter { placed.insert($0).inserted }
          if !row.isEmpty {
            rows[profile, default: []].append(row)
          }
        }
        if let selected = space["selectedTabID"] as? String, let shown = ids[selected] {
          space["selectedTabID"] = shown
        }
        space.removeValue(forKey: "favoriteRows")
      }
      json["profiles"] = profiles.map { profile in
        let id = profile["id"] as! String
        return profile.merging(["favorites": favorites[id] ?? [], "favoriteRows": rows[id] ?? []]) { $1 }
      }
    },
    // Adds each space's tab groups.
    11: { json in
      try eachSpace(&json) { space in
        space["groups"] = [Any]()
      }
    },
    // Gives each window's first space the primary icon, unless it has one.
    12: { json in
      try eachWindow(&json) { spaces in
        if spaces.first?["icon"] as? String == "" {
          spaces[0]["icon"] = Space.primaryIcon
        }
      }
    },
  ]

  private static func eachSpace(_ json: inout [String: Any], _ update: (inout [String: Any]) -> Void) throws {
    try eachWindow(&json) { list in
      for space in list.indices {
        update(&list[space])
      }
    }
  }

  // Each window's list of spaces.
  private static func eachWindow(_ json: inout [String: Any], _ update: (inout [[String: Any]]) -> Void) throws {
    guard var windows = json["windows"] as? [[String: Any]] else { throw Failure.unreadable }
    for window in windows.indices {
      guard
        var spaces = windows[window]["spaces"] as? [String: Any],
        var list = spaces["spaces"] as? [[String: Any]]
      else { throw Failure.unreadable }
      update(&list)
      spaces["spaces"] = list
      windows[window]["spaces"] = spaces
    }
    json["windows"] = windows
  }

  var version = Snapshot.version
  var profiles: IdentifiedArrayOf<Profile>
  var archive: IdentifiedArrayOf<ArchivedTab> = []
  var windows: [Window]
  // The window last made key, brought to the front on relaunch.
  var focusedWindow: UUID?

  struct Window: Codable, Equatable {
    let id: UUID
    var frame: CGRect?
    var sidebar: SidebarFeature.State
    var spaces: SpacesFeature.State
  }

  enum Failure: Error, Equatable {
    case unreadable
    case newerVersion(Int)
    case missingMigration(from: Int)
  }

  static func decode(_ data: Data, migrations: [Int: Migration] = migrations) throws -> Snapshot {
    // Not JSON at all reads as unreadable, like JSON that is not a snapshot.
    guard
      var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      var version = json["version"] as? Int
    else { throw Failure.unreadable }
    guard version <= Self.version else { throw Failure.newerVersion(version) }
    while version < Self.version {
      guard let migrate = migrations[version] else { throw Failure.missingMigration(from: version) }
      try migrate(&json)
      version += 1
      json["version"] = version
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }
}
