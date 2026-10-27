import AppKit
import CryptoKit
import SQLite3

// The favicons of pages imported from another browser, for tabs that have not loaded since: Chrome's favicon service
// knows only pages this browser has visited.
enum ImportedFavicons {
  static let folder = URL.dataDirectory.appending(path: "Imported Favicons")

  static func file(_ page: URL, in folder: URL) -> URL {
    folder.appending(path: SHA256.hash(data: Data(page.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined())
  }

  static func image(_ page: URL, in folder: URL = folder) -> NSImage? {
    NSImage(contentsOf: file(page, in: folder))
  }

  static func save(_ icons: [URL: Data], in folder: URL = folder) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (page, png) in icons {
      try png.write(to: file(page, in: folder))
    }
  }

  // Each page's PNG from the first of the Chromium Favicons databases that has one; those that cannot be read are
  // left out.
  static func read(_ databases: [URL], pages: [URL]) -> [URL: Data] {
    databases.reduce(into: [:]) { icons, database in
      let missing = pages.filter { icons[$0] == nil }
      guard !missing.isEmpty, let found = try? ImportDatabase.withCopy(of: database, { try read(copy: $0, missing) })
      else { return }
      icons.merge(found) { first, _ in first }
    }
  }

  // The page's own favicon, or else the one most of its site's pages have, the bitmap nearest 32 pixels wide. A few
  // pages of a site redirected elsewhere, as to a sign-in page, and have that page's icon.
  private static func read(copy: URL, _ pages: [URL]) throws -> [URL: Data] {
    let query = """
      SELECT b.image_data FROM icon_mapping m JOIN favicons f ON f.id = m.icon_id JOIN favicon_bitmaps b ON b.icon_id = f.id
      WHERE f.icon_type = 1 AND length(b.image_data) > 0 AND (m.page_url = ?1 OR m.page_url LIKE ?2)
      ORDER BY m.page_url = ?1 DESC,
        (SELECT count(*) FROM icon_mapping n WHERE n.icon_id = m.icon_id AND n.page_url LIKE ?2) DESC,
        abs(b.width - 32), b.last_updated DESC LIMIT 1
      """
    var db: OpaquePointer?
    var statement: OpaquePointer?
    defer {
      sqlite3_finalize(statement)
      sqlite3_close(db)
    }
    guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK
    else { throw ImportError.unreadable }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var icons: [URL: Data] = [:]
    for page in pages {
      guard let site = URL(string: "/", relativeTo: page)?.absoluteString else { continue }
      sqlite3_reset(statement)
      sqlite3_bind_text(statement, 1, page.absoluteString, -1, transient)
      sqlite3_bind_text(statement, 2, site + "%", -1, transient)
      if sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) {
        icons[page] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
      }
    }
    return icons
  }
}
