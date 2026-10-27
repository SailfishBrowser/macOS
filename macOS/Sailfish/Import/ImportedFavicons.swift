import AppKit
import CryptoKit

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
    let sites = Dictionary(pages.compactMap { page in site(page).map { (page, $0) } }) { first, _ in first }
    // The pages' own icons, and how many pages of each of their sites have each icon: a site's pages are those that
    // start with its scheme and host.
    var own: [String: [Int]] = [:]
    var shared: [String: [Int: Int]] = [:]
    for (page, site, icon, count) in try ImportDatabase.rows(copy: copy, """
      SELECT page_url, NULL, icon_id, 1 FROM icon_mapping
      WHERE page_url IN (SELECT value FROM json_each(\(try json(pages.map(\.absoluteString)))))
      UNION ALL
      SELECT NULL, s.value, m.icon_id, count(*) FROM json_each(\(try json(Set(sites.values)))) s
      JOIN icon_mapping m ON m.page_url >= s.value AND m.page_url < substr(s.value, 1, length(s.value) - 1) || '0'
      GROUP BY s.value, m.icon_id
      """, { ($0.text(0), $0.text(1), $0.int(2), $0.int(3)) }) {
      if site.isEmpty { own[page, default: []].append(icon) } else { shared[site, default: [:]][icon] = count }
    }
    struct Bitmap {
      var id: Int
      var distance: Int
      var updated: Int
    }
    // Each of those favicons' bitmap nearest 32 pixels wide, the latest of those as near; touch icons are left out.
    let icons = Set(own.values.joined()).union(shared.values.flatMap(\.keys))
    let bitmaps = try Dictionary(
      ImportDatabase.rows(copy: copy, """
        SELECT icon_id, id, distance, last_updated FROM (
          SELECT b.icon_id, b.id, abs(b.width - 32) AS distance, b.last_updated, row_number() OVER (
            PARTITION BY b.icon_id ORDER BY abs(b.width - 32), b.last_updated DESC) AS rank
          FROM favicon_bitmaps b JOIN favicons f ON f.id = b.icon_id
          WHERE b.icon_id IN (\(icons.map(String.init).joined(separator: ","))) AND f.icon_type = 1
            AND length(b.image_data) > 0)
        WHERE rank = 1
        """) { ($0.int(0), Bitmap(id: $0.int(1), distance: $0.int(2), updated: $0.int(3))) },
      uniquingKeysWith: { first, _ in first })
    var chosen: [URL: Int] = [:]
    for (page, site) in sites {
      let counts = shared[site] ?? [:]
      let mine = own[page.absoluteString]?.filter { bitmaps[$0] != nil } ?? []
      chosen[page] = (mine.isEmpty ? counts.keys.filter { bitmaps[$0] != nil } : mine).max { a, b in
        let (x, y) = (bitmaps[a]!, bitmaps[b]!)
        return (counts[a] ?? 0, -x.distance, x.updated) < (counts[b] ?? 0, -y.distance, y.updated)
      }.map { bitmaps[$0]!.id }
    }
    let data = try Dictionary(
      ImportDatabase.rows(copy: copy, """
        SELECT id, image_data FROM favicon_bitmaps WHERE id IN (\(Set(chosen.values).map(String.init).joined(separator: ",")))
        """) { ($0.int(0), $0.data(1)) },
      uniquingKeysWith: { first, _ in first })
    return chosen.compactMapValues { data[$0] }
  }

  // Its scheme and host, as Chromium keeps them, in lower case.
  private static func site(_ page: URL) -> String? {
    URL(string: "/", relativeTo: page)?.absoluteString.lowercased()
  }

  // The strings as an SQL string of a JSON array.
  private static func json(_ strings: some Collection<String>) throws -> String {
    "'" + String(decoding: try JSONEncoder().encode(Array(strings)), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
      + "'"
  }
}
