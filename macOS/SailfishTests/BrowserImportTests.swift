import AppKit
import SQLite3
import XCTest

@testable import Sailfish

final class BrowserImportTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)
  var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: home)
  }

  private func write(_ text: String, _ path: String) throws {
    let file = home.appending(path: path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
  }

  private func tab(_ url: String, _ title: String, _ date: Date) -> ArcData.Row {
    .tab(ArcData.Tab(url: URL(string: url)!, title: title, createdAt: date))
  }

  func testChromiumBookmarksBarComesFirstAndOtherFoldersFollowWhenTheyHoldAny() throws {
    // 13_000_000_000_000_000 microseconds since 1601.
    let json = """
      {"roots": {
        "bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": [
          {"type": "url", "name": "A", "url": "https://a.example/", "date_added": "13000000000000000"},
          {"type": "url", "name": "Run", "url": "javascript:alert(1)"},
          {"type": "folder", "name": "Work", "children": [{"type": "url", "name": "", "url": "https://b.example/"}]}
        ]},
        "other": {"type": "folder", "name": "Other bookmarks", "children": [{"type": "url", "name": "C", "url": "https://c.example/"}]},
        "synced": {"type": "folder", "name": "Mobile bookmarks", "children": []}
      }, "version": 1}
      """
    let epoch = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(try BookmarksReader.chromium(Data(json.utf8)), [
      tab("https://a.example/", "A", Date(timeIntervalSince1970: 13_000_000_000 - 11_644_473_600)),
      .folder(name: "Work", rows: [tab("https://b.example/", "https://b.example/", epoch)]),
      .folder(name: "Other bookmarks", rows: [tab("https://c.example/", "C", epoch)]),
    ])
  }

  func testSafariBookmarksSkipHistoryAndTheReadingList() throws {
    func leaf(_ url: String, _ title: String) -> [String: Any] {
      ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url, "URIDictionary": ["title": title]]
    }
    func list(_ title: String, _ children: [[String: Any]]) -> [String: Any] {
      ["WebBookmarkType": "WebBookmarkTypeList", "Title": title, "Children": children]
    }
    let root = list("", [
      ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
      list("BookmarksBar", [leaf("https://a.example/", "A"), list("Work", [leaf("https://b.example/", "B")])]),
      list("BookmarksMenu", [leaf("https://c.example/", "C")]),
      list("com.apple.ReadingList", [leaf("https://d.example/", "D")]),
    ])
    let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    XCTAssertEqual(try BookmarksReader.safari(data, now: now), [
      tab("https://a.example/", "A", now),
      .folder(name: "Work", rows: [tab("https://b.example/", "B", now)]),
      .folder(name: "Bookmarks Menu", rows: [tab("https://c.example/", "C", now)]),
    ])
  }

  func testOnlyBrowsersWithDataAreOffered() throws {
    let localState = #"{"profile": {"info_cache": {"Default": {"name": "Me"}, "Profile 2": {"name": "Work"}, "Profile 3": {"name": "Empty"}}}}"#
    try write(localState, "Library/Application Support/Google/Chrome/Local State")
    try write("{}", "Library/Application Support/Google/Chrome/Default/Bookmarks")
    try write("", "Library/Application Support/Google/Chrome/Profile 2/History")
    try write("{}", "Library/Application Support/Arc/StorableSidebar.json")
    // Edge's folder without Local State, as an uninstalled Edge leaves it.
    try write("", "Library/Application Support/Microsoft Edge/Default/History")
    try write("", "Library/Safari/History.db")

    let sources = BrowserSources.detect(home: home)
    XCTAssertEqual(sources.map(\.browser), [.arc, .chrome, .safari])
    XCTAssertEqual(sources[1].profiles.map(\.name), ["Me", "Work"])
    XCTAssertEqual(sources[2].profiles.map(\.folder.lastPathComponent), ["Safari"])
  }

  func testArcsPlanetSpaceIconIsTheSailAndEmojiStayTheirOwn() throws {
    let space = { (icon: String) in
      #"{"title": null, "profile": {"default": true}, "containerIDs": [], "customInfo": {"iconType": \#(icon)}}"#
    }
    let sidebar = """
      {"sidebar": {"containers": [{"spaces": ["a", \(space(#"{"icon": "planet"}"#)), "b", \(space(#"{"emoji_v2": "🐟"}"#)), \
      "c", \(space(#"{"icon": "leaf"}"#))], "items": []}]}}
      """
    try write(sidebar, "Arc/StorableSidebar.json")
    XCTAssertEqual(try ArcReader.read(home.appending(path: "Arc")).spaces.map(\.icon), [Space.primaryIcon, "🐟", ""])
  }

  func testAMissingBookmarksFileIsNoBookmarks() throws {
    let profile = BrowserProfile(name: "Me", folder: home.appending(path: "Default"))
    XCTAssertEqual(try BookmarksReader.read(.chrome, profile, now: now), [])
  }

  // A Chromium Favicons database whose icons are (page, icon type, width, bytes); pages with the same bytes share an icon.
  private func favicons(_ path: String, _ icons: [(String, Int, Int, String)]) throws -> URL {
    let file = home.appending(path: path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var sql = """
      CREATE TABLE favicons (id INTEGER PRIMARY KEY, url LONGVARCHAR NOT NULL, icon_type INTEGER DEFAULT 1);
      CREATE TABLE favicon_bitmaps (id INTEGER PRIMARY KEY, icon_id INTEGER NOT NULL, last_updated INTEGER DEFAULT 0,
        image_data BLOB, width INTEGER DEFAULT 0, height INTEGER DEFAULT 0);
      CREATE TABLE icon_mapping (id INTEGER PRIMARY KEY, page_url LONGVARCHAR NOT NULL, icon_id INTEGER);
      """
    var ids: [String: Int] = [:]
    for (page, type, width, bytes) in icons {
      if ids[bytes] == nil {
        ids[bytes] = ids.count
        let hex = Data(bytes.utf8).map { String(format: "%02x", $0) }.joined()
        sql += """
          INSERT INTO favicons VALUES (\(ids[bytes]!), '\(page)favicon.ico', \(type));
          INSERT INTO favicon_bitmaps (icon_id, image_data, width, height) VALUES (\(ids[bytes]!), X'\(hex)', \(width), \(width));
          """
      }
      sql += "INSERT INTO icon_mapping (page_url, icon_id) VALUES ('\(page)', \(ids[bytes]!));"
    }
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)
    return file
  }

  func testImportedFaviconsArePagesOwnOrElseTheirSitesNearest32PixelsWide() throws {
    let first = try favicons("Default/Favicons", [
      ("https://docs.example/sheet", 1, 16, "sheet16"),
      ("https://docs.example/sheet", 1, 64, "sheet64"),
      ("https://docs.example/sheet", 1, 32, "sheet32"),
      ("https://docs.example/doc", 1, 32, "doc32"),
      ("https://mail.example/", 1, 16, "mail16"),
      ("https://touch.example/", 2, 32, "touch"),
    ])
    let second = try favicons("Profile 1/Favicons", [
      ("https://docs.example/sheet", 1, 32, "other"),
      ("https://work.example/", 1, 32, "work32"),
    ])
    let page = { URL(string: $0)! }
    let icons = ImportedFavicons.read(
      [home.appending(path: "Missing/Favicons"), first, second],
      pages: ["https://docs.example/sheet", "https://mail.example/inbox", "https://touch.example/", "https://work.example/",
              "https://none.example/"].map(page))
    XCTAssertEqual(icons.mapValues { String(decoding: $0, as: UTF8.self) }, [
      page("https://docs.example/sheet"): "sheet32",
      page("https://mail.example/inbox"): "mail16",
      page("https://work.example/"): "work32",
    ])
  }

  // Pages of a site that bounced to its sign-in page have that page's icon; the site's own one is the one most have.
  func testImportedFaviconsOfAnotherPageOfTheSiteAreTheOneMostOfItsPagesHave() throws {
    let database = try favicons("Default/Favicons", [
      ("https://calendar.example/week", 1, 16, "calendar"),
      ("https://calendar.example/month", 1, 16, "calendar"),
      ("https://calendar.example/", 1, 32, "signin"),
      ("https://calendar.example/r", 1, 32, "signin-r"),
    ])
    let page = URL(string: "https://calendar.example/day")!
    XCTAssertEqual(ImportedFavicons.read([database], pages: [page]).mapValues { String(decoding: $0, as: UTF8.self) }, [
      page: "calendar"
    ])
  }

  // A page's own icon wins over the one its site's pages share; a site is its scheme and whole host, in any case.
  func testImportedFaviconsOfASiteAreItsOwnHostsAndAPagesOwnComesFirst() throws {
    let database = try favicons("Default/Favicons", [
      ("https://news.example/a", 1, 32, "news"),
      ("https://news.example/b", 1, 32, "news"),
      ("https://news.example/odd", 1, 32, "odd"),
      ("https://news.example.org/a", 1, 32, "org"),
      ("https://news.example.org/b", 1, 32, "org"),
      ("https://news.example.org/c", 1, 32, "org"),
      ("http://news.example/", 1, 32, "http"),
    ])
    let pages = ["https://news.example/odd", "https://NEWS.example/new", "https://news.example.org/new"]
      .map { URL(string: $0)! }
    XCTAssertEqual(ImportedFavicons.read([database], pages: pages).mapValues { String(decoding: $0, as: UTF8.self) }, [
      pages[0]: "odd", pages[1]: "news", pages[2]: "org",
    ])
  }

  func testSavedImportedFaviconsAreThePagesImages() throws {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let page = URL(string: "https://a.example/")!
    let folder = home.appending(path: "Imported Favicons")
    try ImportedFavicons.save([page: rep.representation(using: .png, properties: [:])!], in: folder)
    XCTAssertEqual(ImportedFavicons.image(page, in: folder)?.size, NSSize(width: 2, height: 2))
    XCTAssertNil(ImportedFavicons.image(URL(string: "https://b.example/")!, in: folder))
  }
}
