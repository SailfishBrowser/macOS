import Foundation

// A browser's bookmarks as pinned rows: the bookmarks bar's own rows first, then the other top-level folders that
// hold anything, as folders. Bookmarklets are left out, as a pinned tab cannot run them.
enum BookmarksReader {
  static func read(_ browser: SourceBrowser, _ profile: BrowserProfile, now: Date) throws -> [ArcData.Row] {
    let file = browser.bookmarksFile(profile)
    // Chromium writes the file with the first bookmark.
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch let error as CocoaError where ImportError.isDenied(error) {
      throw ImportError.needsFullDiskAccess
    }
    do {
      return browser == .safari ? try safari(data, now: now) : try chromium(data)
    } catch {
      throw ImportError.unreadable
    }
  }

  private struct ChromiumFile: Decodable {
    struct Node: Decodable {
      let type: String
      let name: String
      let url: String?
      // Microseconds since 1601.
      let date_added: String?
      let children: [Node]?
    }
    let roots: [String: Node]
  }

  static func chromium(_ data: Data) throws -> [ArcData.Row] {
    let roots = try JSONDecoder().decode(ChromiumFile.self, from: data).roots
    func rows(_ nodes: [ChromiumFile.Node]) -> [ArcData.Row] {
      nodes.compactMap { node in
        if node.type == "folder" { return .folder(name: node.name, rows: rows(node.children ?? [])) }
        let added = node.date_added.flatMap(Double.init).map { $0 / 1e6 - 11_644_473_600 } ?? 0
        return tab(node.url, node.name, Date(timeIntervalSince1970: added))
      }
    }
    let others = ["other", "synced"].compactMap { roots[$0] }.filter { !($0.children ?? []).isEmpty }
    return rows(roots["bookmark_bar"]?.children ?? []) + others.map { .folder(name: $0.name, rows: rows($0.children ?? [])) }
  }

  private struct SafariNode: Decodable {
    struct URIDictionary: Decodable { let title: String? }
    let WebBookmarkType: String
    let Title: String?
    let URLString: String?
    let URIDictionary: URIDictionary?
    let Children: [SafariNode]?
  }

  // Safari's top level holds the bookmarks bar, the menu, the reading list and a proxy for history.
  static func safari(_ data: Data, now: Date) throws -> [ArcData.Row] {
    let root = try PropertyListDecoder().decode(SafariNode.self, from: data)
    func rows(_ nodes: [SafariNode]) -> [ArcData.Row] {
      nodes.compactMap { node in
        switch node.WebBookmarkType {
        case "WebBookmarkTypeList": .folder(name: node.Title ?? "Untitled", rows: rows(node.Children ?? []))
        case "WebBookmarkTypeLeaf": tab(node.URLString, node.URIDictionary?.title ?? "", now)
        default: nil
        }
      }
    }
    let top = (root.Children ?? []).filter { $0.WebBookmarkType == "WebBookmarkTypeList" && $0.Title != "com.apple.ReadingList" }
    let bar = top.first { $0.Title == "BookmarksBar" }
    let others = top.filter { $0.Title != "BookmarksBar" && !($0.Children ?? []).isEmpty }
    return rows(bar?.Children ?? []) + others.map {
      .folder(name: $0.Title == "BookmarksMenu" ? "Bookmarks Menu" : $0.Title ?? "Untitled", rows: rows($0.Children ?? []))
    }
  }

  // Firefox's places database: the toolbar's own rows first, then the menu, other and mobile bookmarks that hold any,
  // as folders.
  static func firefox(_ file: URL) throws -> [ArcData.Row] {
    struct Node {
      let id, type, parent: Int
      let title, url, guid: String
      let added: Date
    }
    // Types: 1 a bookmark, 2 a folder; dateAdded is in microseconds since 1970.
    let nodes = try ImportDatabase.rows(file, """
      SELECT b.id, b.type, b.parent, b.title, p.url, b.guid, b.dateAdded FROM moz_bookmarks b
      LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position
      """) { row in
      Node(
        id: row.int(0), type: row.int(1), parent: row.int(2), title: row.text(3), url: row.text(4), guid: row.text(5),
        added: Date(timeIntervalSince1970: row.double(6) / 1e6))
    }
    let children = Dictionary(grouping: nodes, by: \.parent)
    func rows(_ parent: Int) -> [ArcData.Row] {
      (children[parent] ?? []).compactMap { node in
        switch node.type {
        case 1: tab(node.url, node.title, node.added)
        case 2: .folder(name: node.title, rows: rows(node.id))
        default: nil
        }
      }
    }
    let roots = Dictionary(nodes.map { ($0.guid, $0.id) }) { first, _ in first }
    let others = [("menu________", "Bookmarks Menu"), ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile Bookmarks")]
      .compactMap { guid, name -> ArcData.Row? in
        guard let id = roots[guid], case let folder = rows(id), !folder.isEmpty else { return nil }
        return .folder(name: name, rows: folder)
      }
    return (roots["toolbar_____"].map(rows) ?? []) + others
  }

  private static func tab(_ string: String?, _ title: String, _ added: Date) -> ArcData.Row? {
    guard let url = string.flatMap(URL.init(string:)), let scheme = url.scheme, scheme != "javascript" else { return nil }
    return .tab(ArcData.Tab(url: url, title: title.isEmpty ? url.absoluteString : title, createdAt: added))
  }
}
