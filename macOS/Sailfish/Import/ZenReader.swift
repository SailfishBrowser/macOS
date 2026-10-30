import Compression
import Foundation

// What a Zen profile holds that this browser takes, as Arc's: its spaces with their themes, pinned rows and open
// tabs, each container's essentials and the bookmarks. Zen 1.18 and later keep the sidebar in zen-sessions.jsonlz4
// and copies in zen-sessions-backup; the newest is read. A container's spaces and essentials go to the profile of its
// name, those of none to the first.
enum ZenReader {
  static func read(_ profile: URL, now: Date) throws -> ArcData {
    guard let file = sessionFile(profile) else { throw ArcImportError.notFound }
    do {
      guard let json = mozLZ4(try Data(contentsOf: file)) else { throw ArcImportError.unreadable }
      var data = data(try JSONDecoder().decode(Session.self, from: json), containers: try containers(profile), now: now)
      let bookmarks = try BookmarksReader.firefox(profile.appending(path: "places.sqlite"))
      data.bookmarks = bookmarks.isEmpty ? nil : ArcData.Space(name: "Zen Bookmarks", icon: "", pinned: bookmarks, today: [])
      return data
    } catch let error as ArcImportError {
      throw error
    } catch {
      throw ArcImportError.unreadable
    }
  }

  static func sessionFile(_ profile: URL) -> URL? {
    let backups = (try? FileManager.default.contentsOfDirectory(
      at: profile.appending(path: "zen-sessions-backup"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return ([profile.appending(path: "zen-sessions.jsonlz4")] + backups.filter { $0.pathExtension == "jsonlz4" })
      .compactMap { file in
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (file, $0) }
      }
      .max { $0.1 < $1.1 }?.0
  }

  // Mozilla's LZ4 file: a magic, the size decompressed as 4 bytes little-endian, then one raw LZ4 block.
  static func mozLZ4(_ data: Data) -> Data? {
    let bytes = [UInt8](data)
    guard bytes.count >= 12, bytes.starts(with: Array("mozLz40\0".utf8)) else { return nil }
    let size = bytes[8..<12].reversed().reduce(0) { $0 << 8 | Int($1) }
    var output = [UInt8](repeating: 0, count: size)
    let count = compression_decode_buffer(&output, size, Array(bytes[12...]), bytes.count - 12, nil, COMPRESSION_LZ4_RAW)
    return count == size ? Data(output) : nil
  }

  // The names of the containers by id: those the user gave, else Firefox's own of the four it comes with.
  static func containers(_ profile: URL) throws -> [Int: String] {
    struct File: Decodable {
      struct Identity: Decodable {
        let userContextId: Int
        let `public`: Bool
        let name: String?
      }
      let identities: [Identity]
    }
    let file = profile.appending(path: "containers.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
    let builtIn = [1: "Personal", 2: "Work", 3: "Banking", 4: "Shopping"]
    let identities = try JSONDecoder().decode(File.self, from: Data(contentsOf: file)).identities.filter(\.public)
    return Dictionary(identities.compactMap { identity in
      (identity.name ?? builtIn[identity.userContextId]).map { (identity.userContextId, $0) }
    }) { first, _ in first }
  }

  // The cookies not yet expired, each with its container's name, nil for none. Those of containers since removed and
  // partitioned ones, which belong to the site that embedded theirs, are left out.
  static func cookies(_ profile: URL, now: Date) throws -> [(container: String?, cookie: ImportedCookie)] {
    let containers = try containers(profile)
    let query = """
      SELECT host, name, value, path, creationTime, expiry, lastAccessed, isSecure, isHttpOnly, sameSite, originAttributes
      FROM moz_cookies
      """
    // Microseconds since 1970, and the expiry milliseconds.
    func date(_ time: Int, _ perSecond: Double = 1e6) -> Date { Date(timeIntervalSince1970: Double(time) / perSecond) }
    return try ImportDatabase.rows(profile.appending(path: "cookies.sqlite"), query) { row in
      let attributes = originAttributes(row.text(10))
      guard attributes.keys.allSatisfy({ $0 == "userContextId" }), let id = Int(attributes["userContextId"] ?? "0"),
        id == 0 || containers[id] != nil
      else { return nil }
      let expiry = date(row.int(5), 1e3)
      guard expiry >= now else { return nil }
      let isSecure = row.int(7) != 0
      // Firefox's 0 is None, which Chromium takes only for secure cookies; others are unspecified.
      let sameSite = switch row.int(9) {
      case 1, 2: row.int(9)
      case 0 where isSecure: 0
      default: -1
      }
      return (id == 0 ? nil : containers[id], ImportedCookie(
        name: row.text(1), value: row.text(2), domain: row.text(0), path: row.text(3), creation: date(row.int(4)),
        expiry: expiry, lastAccess: date(row.int(6)), isSecure: isSecure, isHTTPOnly: row.int(8) != 0, sameSite: sameSite))
    }
  }

  // "^userContextId=2&partitionKey=…" as its keys and values.
  static func originAttributes(_ text: String) -> [String: String] {
    Dictionary(text.drop { $0 == "^" }.split(separator: "&").map { pair in
      let parts = pair.split(separator: "=", maxSplits: 1)
      return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
    }) { $1 }
  }

  private static func data(_ session: Session, containers: [Int: String], now: Date) -> ArcData {
    let folders = Dictionary(session.folders.map { ($0.id, $0) }) { first, _ in first }
    // The folders a tab is in, outermost first; a split view's tabs stand in its place.
    func path(_ id: String?, within: Set<String> = []) -> [String] {
      guard let id, !within.contains(id), let folder = folders[id] else { return [] }
      return path(folder.parentId, within: within.union([id])) + (folder.splitViewGroup == true ? [] : [id])
    }
    // Tabs come in the sidebar's order, so a folder stands where its first tab, or the empty one it keeps, is.
    func rows(_ tabs: [Session.Tab]) -> [ArcData.Row] {
      enum Item {
        case tab(ArcData.Tab)
        case folder(String)
      }
      var items: [String?: [Item]] = [:]
      var placed: Set<String> = []
      for tab in tabs {
        var parent: String?
        for id in path(tab.groupId) {
          if placed.insert(id).inserted {
            items[parent, default: []].append(.folder(id))
          }
          parent = id
        }
        if let made = self.tab(tab, now: now) {
          items[parent, default: []].append(.tab(made))
        }
      }
      func children(_ parent: String?) -> [ArcData.Row] {
        (items[parent] ?? []).map { item in
          switch item {
          case let .tab(tab): .tab(tab)
          case let .folder(id): .folder(name: folders[id]!.name, rows: children(id))
          }
        }
      }
      return children(nil)
    }
    let container = { (id: Int?) in id.flatMap { containers[$0] } }

    var data = ArcData()
    data.spaces = session.spaces.map { space in
      let tabs = session.tabs.filter { $0.zenWorkspace == space.uuid && $0.zenEssential != true }
      return ArcData.Space(
        name: space.name, icon: space.icon.flatMap { $0.contains("/") ? nil : $0 } ?? "",
        profile: container(space.containerTabId), pinned: rows(tabs.filter { $0.pinned == true }),
        today: tabs.filter { $0.pinned != true }.compactMap { tab($0, now: now) }, theme: theme(space.theme))
    }
    for tab in session.tabs where tab.zenEssential == true {
      guard let made = self.tab(tab, now: now) else { continue }
      let profile = container(tab.userContextId)
      if let index = data.favorites.firstIndex(where: { $0.profile == profile }) {
        data.favorites[index].tabs.append(made)
      } else {
        data.favorites.append(ArcData.Favorites(profile: profile, tabs: [made]))
      }
    }
    return data
  }

  // A page's tab, at the URL it was pinned at; Zen's own pages, empty tabs and glances are left out.
  private static func tab(_ tab: Session.Tab, now: Date) -> ArcData.Tab? {
    guard tab.zenIsEmpty != true, tab.zenIsGlance != true, tab.entries.indices.contains(tab.index - 1) else { return nil }
    let entry = tab.entries[tab.index - 1]
    guard let url = (tab._zenPinnedInitialState?.entry?.url ?? entry.url).flatMap(URL.init(string:)),
      ["http", "https", "file"].contains(url.scheme)
    else { return nil }
    return ArcData.Tab(
      url: url, title: entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? url.absoluteString,
      customTitle: tab.zenStaticLabel, createdAt: now)
  }

  // Up to three of the gradient's colors; those picked as custom strings are left out.
  private static func theme(_ theme: Session.Theme?) -> SpaceTheme {
    let colors = (theme?.gradientColors ?? []).compactMap(\.c).filter { $0.count == 3 }.prefix(3).map {
      $0.reduce(UInt32(0)) { $0 << 8 | UInt32(min(max($1.rounded(), 0), 255)) }
    }
    guard let theme, !colors.isEmpty else { return SpaceTheme() }
    return SpaceTheme(colors: colors, grain: theme.texture, intensity: theme.opacity)
  }
}

private struct Session: Decodable {
  struct Space: Decodable {
    let uuid: String
    let name: String
    // An emoji or one of Zen's SVG icons.
    let icon: String?
    let containerTabId: Int?
    let theme: Theme?
  }

  struct Theme: Decodable {
    struct Color: Decodable {
      enum CodingKeys: CodingKey { case c }
      // Red, green and blue, or a custom string.
      let c: [Double]?

      init(from decoder: Decoder) throws {
        c = try? decoder.container(keyedBy: CodingKeys.self).decode([Double].self, forKey: .c)
      }
    }
    let gradientColors: [Color]
    let opacity: Double
    let texture: Double
  }

  struct Tab: Decodable {
    struct Entry: Decodable {
      let url: String?
      let title: String?
    }
    struct Initial: Decodable { let entry: Entry? }
    let entries: [Entry]
    // 1-based.
    let index: Int
    let pinned: Bool?
    let zenEssential: Bool?
    let zenWorkspace: String?
    let zenStaticLabel: String?
    let zenIsEmpty: Bool?
    let zenIsGlance: Bool?
    let userContextId: Int?
    // The folder it is in.
    let groupId: String?
    let _zenPinnedInitialState: Initial?
  }

  struct Folder: Decodable {
    let id: String
    let name: String
    let parentId: String?
    let splitViewGroup: Bool?
  }

  let tabs: [Tab]
  let folders: [Folder]
  let spaces: [Space]
}
