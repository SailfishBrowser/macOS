import SQLite3
import XCTest

@testable import Sailfish

final class ZenReaderTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  var profile: URL!

  override func setUpWithError() throws {
    profile = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: profile)
  }

  private func write(_ data: Data, _ path: String, modified: Date? = nil) throws {
    let file = profile.appending(path: path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file)
    if let modified {
      try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }
  }

  // A mozlz4 file of one LZ4 block of literals only, which needs 15 bytes or more.
  private func mozLZ4(_ text: String) -> Data {
    let bytes = Array(text.utf8)
    var block: [UInt8] = [0xF0]
    var rest = bytes.count - 15
    while rest >= 255 {
      block.append(255)
      rest -= 255
    }
    block.append(UInt8(rest))
    return Data("mozLz40\0".utf8) + withUnsafeBytes(of: UInt32(bytes.count).littleEndian) { Data($0) } + Data(block + bytes)
  }

  private func database(_ path: String, _ sql: String) throws {
    let file = profile.appending(path: path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    sqlite3_close(db)
  }

  // Firefox's roots, a toolbar bookmark and folder, a menu bookmark, a separator and visited and unvisited places.
  private func places() throws {
    try database("places.sqlite", """
      CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0,
        hidden INTEGER DEFAULT 0 NOT NULL, typed INTEGER DEFAULT 0 NOT NULL, last_visit_date INTEGER);
      CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER,
        position INTEGER, title LONGVARCHAR, dateAdded INTEGER, guid TEXT);
      INSERT INTO moz_places VALUES (1, 'https://a.example/', 'A', 2, 0, 1, 1700000000000000),
        (2, 'https://b.example/', NULL, 0, 0, 0, NULL), (3, 'https://c.example/', 'C', 1, 1, 0, 1700000000000000),
        (4, 'https://d.example/', 'D', 0, 0, 0, NULL);
      INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 0, 'root________'),
        (2, 2, NULL, 1, 0, 'menu', 0, 'menu________'), (3, 2, NULL, 1, 1, 'toolbar', 0, 'toolbar_____'),
        (4, 2, NULL, 1, 3, 'unfiled', 0, 'unfiled_____'),
        (5, 1, 2, 3, 1, 'Bee', 1700000000000000, 'b1'), (6, 2, NULL, 3, 0, 'Work', 0, 'f1'),
        (7, 1, 4, 6, 0, 'Dee', 0, 'd1'), (8, 3, NULL, 3, 2, '', 0, 's1'), (9, 1, 1, 2, 0, 'Ay', 0, 'a1');
      """)
  }

  private func tab(_ url: String, _ title: String, customTitle: String? = nil) -> ArcData.Tab {
    ArcData.Tab(url: URL(string: url)!, title: title, customTitle: customTitle, createdAt: now)
  }

  func testMozLZ4IsAMagicTheSizeAndOneRawLZ4Block() {
    // "abc", then 9 bytes from 3 back, then the last literals.
    let block = Data([0x35, 0x61, 0x62, 0x63, 0x03, 0x00, 0x50]) + Data("-----".utf8)
    let size = Data([17, 0, 0, 0])
    XCTAssertEqual(ZenReader.mozLZ4(Data("mozLz40\0".utf8) + size + block), Data("abcabcabcabc-----".utf8))
    XCTAssertNil(ZenReader.mozLZ4(Data("mozLz41\0".utf8) + size + block))
  }

  func testTheNewestSessionsSpacesComeWithTheirThemesFoldersEssentialsAndOpenTabs() throws {
    let entry = { (url: String, extra: String) in
      #"{"entries": [{"url": "\#(url)", "title": "T"}], "index": 1, \#(extra)}"#
    }
    let session = """
      {"lastCollected": 1, "tabs": [
        \(entry("https://mail.example/", #""pinned": true, "zenEssential": true, "zenWorkspace": null, "userContextId": 0"#)),
        \(entry("https://docs.example/", #""pinned": true, "zenEssential": true, "zenWorkspace": null, "userContextId": 2"#)),
        \(entry("https://a.example/moved", #""pinned": true, "zenWorkspace": "h", "zenStaticLabel": "Mine", "_zenPinnedInitialState": {"entry": {"url": "https://a.example/"}}"#)),
        \(entry("about:blank", #""pinned": true, "zenWorkspace": "h", "groupId": "outer", "zenIsEmpty": true"#)),
        \(entry("https://b.example/", #""pinned": true, "zenWorkspace": "h", "groupId": "outer", "_zenPinnedInitialState": {"entry": {}}"#)),
        \(entry("about:blank", #""pinned": true, "zenWorkspace": "h", "groupId": "nested", "zenIsEmpty": true"#)),
        \(entry("https://c.example/", #""pinned": true, "zenWorkspace": "h", "groupId": "nested""#)),
        \(entry("https://d.example/", #""pinned": true, "zenWorkspace": "h""#)),
        {"entries": [{"url": "https://old.example/"}, {"url": "https://e.example/", "title": ""}], "index": 2, "pinned": false, "zenWorkspace": "h"},
        \(entry("https://glance.example/", #""pinned": false, "zenWorkspace": "h", "zenIsGlance": true"#)),
        \(entry("about:newtab", #""pinned": false, "zenWorkspace": "h""#)),
        \(entry("https://w.example/", #""pinned": true, "zenWorkspace": "w", "userContextId": 2"#))
      ], "folders": [
        {"id": "outer", "name": "Outer", "parentId": null, "splitViewGroup": false, "userIcon": "chrome://browser/skin/zen-icons/selectable/star.svg"},
        {"id": "nested", "name": "Nested", "parentId": "outer", "splitViewGroup": false, "userIcon": ""}
      ], "splitViewData": [], "groups": [], "spaces": [
        {"uuid": "h", "name": "Home", "icon": "🏠", "containerTabId": 0, "theme": {"type": "gradient", "gradientColors": [
          {"c": [255, 120, 30], "isPrimary": true}, {"c": "#00ff00", "isCustom": true}, {"c": [40, 90, 200]}
        ], "opacity": 0.7, "texture": 0.25}},
        {"uuid": "w", "name": "Work", "icon": "chrome://browser/skin/zen-icons/selectable/briefcase.svg", "containerTabId": 2,
          "theme": {"type": "gradient", "gradientColors": [], "opacity": 0.5, "texture": 0}}
      ]}
      """
    let old = #"{"tabs": [], "folders": [], "spaces": [{"uuid": "o", "name": "Old"}]}"#
    try write(mozLZ4(old), "zen-sessions.jsonlz4", modified: now - 3600)
    try write(mozLZ4(session), "zen-sessions-backup/clean.jsonlz4", modified: now)
    try write(mozLZ4(old), "zen-sessions-backup/zen-sessions-2026-01-01-00.jsonlz4", modified: now - 7200)
    let containers = """
      {"version": 8, "identities": [{"icon": "briefcase", "color": "orange", "public": true, "userContextId": 2},
        {"name": "Lab", "public": true, "userContextId": 6}, {"name": "userContextIdInternal.thumbnail", "public": false, "userContextId": 5}]}
      """
    try write(Data(containers.utf8), "containers.json")
    try places()

    let data = try ZenReader.read(profile, now: now)
    XCTAssertEqual(data.spaces, [
      ArcData.Space(
        name: "Home", icon: "🏠", profile: nil,
        pinned: [
          .tab(tab("https://a.example/", "T", customTitle: "Mine")),
          .folder(name: "Outer", rows: [.tab(tab("https://b.example/", "T")), .folder(name: "Nested", rows: [.tab(tab("https://c.example/", "T"))])]),
          .tab(tab("https://d.example/", "T")),
        ],
        today: [tab("https://e.example/", "https://e.example/")],
        theme: SpaceTheme(colors: [0xFF781E, 0x285AC8], grain: 0.25, intensity: 0.7)),
      ArcData.Space(name: "Work", icon: "", profile: "Work", pinned: [.tab(tab("https://w.example/", "T"))], today: []),
    ])
    XCTAssertEqual(data.favorites, [
      ArcData.Favorites(profile: nil, tabs: [tab("https://mail.example/", "T")]),
      ArcData.Favorites(profile: "Work", tabs: [tab("https://docs.example/", "T")]),
    ])
    XCTAssertEqual(data.bookmarks?.name, "Zen Bookmarks")
    XCTAssertEqual(try ZenReader.containers(profile), [2: "Work", 6: "Lab"])
  }

  func testAProfileWithoutASessionFileIsNotZenData() {
    XCTAssertThrowsError(try ZenReader.read(profile, now: now)) { XCTAssertEqual($0 as? ArcImportError, .notFound) }
  }

  func testBookmarksAreTheToolbarsRowsThenTheOtherRootsThatHoldAnyAndHistoryIsThePagesVisited() throws {
    try places()
    let added = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertEqual(try BookmarksReader.firefox(profile.appending(path: "places.sqlite")), [
      .folder(name: "Work", rows: [.tab(ArcData.Tab(url: URL(string: "https://d.example/")!, title: "Dee", createdAt: Date(timeIntervalSince1970: 0)))]),
      .tab(ArcData.Tab(url: URL(string: "https://b.example/")!, title: "Bee", createdAt: added)),
      .folder(name: "Bookmarks Menu", rows: [.tab(ArcData.Tab(url: URL(string: "https://a.example/")!, title: "Ay", createdAt: Date(timeIntervalSince1970: 0)))]),
    ])
    let source = SourceBrowser.zen.historySource(BrowserProfile(name: "Default", folder: profile))
    XCTAssertEqual(try HistoryReader.read(source), [
      HistoryEntry(url: "https://a.example/", title: "A", visitCount: 2, typedCount: 1, lastVisit: added),
    ])
  }

  func testCookiesKeepTheirContainersNameAndThoseOfRemovedContainersOrPartitionedOnesAreLeftOut() throws {
    try write(Data(#"{"identities": [{"public": true, "userContextId": 2}, {"name": "Lab", "public": true, "userContextId": 6}]}"#.utf8), "containers.json")
    // Expiry in milliseconds, the other times in microseconds, as Zen 1.23 writes them.
    let later = 1_900_000_000_000
    try database("cookies.sqlite", """
      CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT, value TEXT,
        host TEXT, path TEXT, expiry INTEGER, lastAccessed INTEGER, creationTime INTEGER, isSecure INTEGER,
        isHttpOnly INTEGER, inBrowserElement INTEGER DEFAULT 0, sameSite INTEGER DEFAULT 0, schemeMap INTEGER DEFAULT 0,
        isPartitionedAttributeSet INTEGER DEFAULT 0, updateTime INTEGER);
      INSERT INTO moz_cookies (originAttributes, name, value, host, path, expiry, lastAccessed, creationTime, isSecure,
        isHttpOnly, sameSite) VALUES
        ('', 'plain', 'v0', '.a.example', '/', \(later), 1700000000000000, 1600000000000000, 1, 1, 1),
        ('^userContextId=2', 'work', 'v2', 'a.example', '/w', \(later), 0, 0, 1, 0, 0),
        ('^userContextId=6', 'lab', 'v6', 'a.example', '/', \(later), 0, 0, 0, 0, 0),
        ('^userContextId=9', 'gone', 'v9', 'a.example', '/', \(later), 0, 0, 0, 0, 0),
        ('^partitionKey=%28https%2Cb.example%29', 'embedded', 'p', 'a.example', '/', \(later), 0, 0, 1, 0, 0),
        ('', 'old', 'x', 'a.example', '/', 1700000000000, 0, 0, 0, 0, 0);
      """)
    let expiry = Date(timeIntervalSince1970: 1_900_000_000)
    let epoch = Date(timeIntervalSince1970: 0)
    let cookies = try ZenReader.cookies(profile, now: now)
    XCTAssertEqual(cookies.map(\.container), [nil, "Work", "Lab"])
    XCTAssertEqual(cookies.map(\.cookie), [
      ImportedCookie(
        name: "plain", value: "v0", domain: ".a.example", path: "/", creation: Date(timeIntervalSince1970: 1_600_000_000),
        expiry: expiry, lastAccess: Date(timeIntervalSince1970: 1_700_000_000), isSecure: true, isHTTPOnly: true, sameSite: 1),
      ImportedCookie(
        name: "work", value: "v2", domain: "a.example", path: "/w", creation: epoch, expiry: expiry, lastAccess: epoch,
        isSecure: true, isHTTPOnly: false, sameSite: 0),
      ImportedCookie(
        name: "lab", value: "v6", domain: "a.example", path: "/", creation: epoch, expiry: expiry, lastAccess: epoch,
        isSecure: false, isHTTPOnly: false, sameSite: -1),
    ])
    XCTAssertEqual(ZenReader.originAttributes("^userContextId=2&partitionKey=%28https%2Cb.example%29"), [
      "userContextId": "2", "partitionKey": "%28https%2Cb.example%29",
    ])
    XCTAssertEqual(ZenReader.originAttributes(""), [:])
  }

  func testZensProfilesWithHistoryAreOfferedTheInstallsDefaultFirst() throws {
    let root = profile.appending(path: "Library/Application Support/zen")
    let ini = """
      [General]\r\nStartWithLastProfile=1\r\n\r\n[Profile0]\r\nName=Other\r\nIsRelative=1\r\nPath=Profiles/b.Other\r\nDefault=1\r\n
      [Profile1]\r\nName=Default (release)\r\nIsRelative=1\r\nPath=Profiles/a.Default (release)\r\n
      [Profile2]\r\nName=Empty\r\nIsRelative=1\r\nPath=Profiles/c.Empty\r\n
      """
    try write(Data(ini.utf8), "Library/Application Support/zen/profiles.ini")
    try write(Data(), "Library/Application Support/zen/Profiles/b.Other/places.sqlite")
    try write(Data(), "Library/Application Support/zen/Profiles/a.Default (release)/places.sqlite")
    try write(Data(), "Library/Application Support/zen/Profiles/c.Empty/times.json")
    XCTAssertEqual(BrowserSources.zenProfiles(root).map(\.name), ["Other", "Default (release)"])

    try write(Data("[6ED35B3CA1B5D3AF]\nDefault=Profiles/a.Default (release)\nLocked=1\n".utf8), "Library/Application Support/zen/installs.ini")
    let sources = BrowserSources.detect(home: profile)
    XCTAssertEqual(sources.map(\.browser), [.zen])
    XCTAssertEqual(sources[0].profiles, [
      BrowserProfile(name: "Default (release)", folder: root.appending(path: "Profiles/a.Default (release)")),
      BrowserProfile(name: "Other", folder: root.appending(path: "Profiles/b.Other")),
    ])
  }
}
