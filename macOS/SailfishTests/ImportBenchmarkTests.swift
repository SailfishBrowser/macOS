import CommonCrypto
import CryptoKit
import SQLite3
import XCTest

@testable import Sailfish

// An import from 15 synthetic profiles at the scale of a heavy Arc user's: each with 50k favicon mappings over 20k
// bitmaps, 100k history URLs, 10k cookies and 500 passwords.
final class ImportBenchmarkTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let key = SafeStorage.key(password: Data("test-password".utf8))
  var home: URL!

  override func setUpWithError() throws {
    home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: home)
  }

  private func database(_ name: String, _ sql: String, rows: ((OpaquePointer?) -> Void)? = nil) throws -> URL {
    let file = home.appending(path: name)
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, "BEGIN; \(sql)", nil, nil, nil), SQLITE_OK)
    rows?(db)
    XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
    return file
  }

  private func numbers(_ count: Int) -> String {
    "WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM n WHERE i < \(count - 1))"
  }

  // 5,000 sites of 10 pages each, 7 of them with the site's main icon; every icon has a 16 and a 32 pixel bitmap.
  private func favicons() throws -> URL {
    try database("Favicons", """
      CREATE TABLE favicons (id INTEGER PRIMARY KEY, url LONGVARCHAR NOT NULL, icon_type INTEGER DEFAULT 1);
      CREATE INDEX favicons_url ON favicons(url);
      CREATE TABLE favicon_bitmaps (id INTEGER PRIMARY KEY, icon_id INTEGER NOT NULL, last_updated INTEGER DEFAULT 0,
        image_data BLOB, width INTEGER DEFAULT 0, height INTEGER DEFAULT 0);
      CREATE INDEX favicon_bitmaps_icon_id ON favicon_bitmaps(icon_id);
      CREATE TABLE icon_mapping (id INTEGER PRIMARY KEY, page_url LONGVARCHAR NOT NULL, icon_id INTEGER);
      CREATE INDEX icon_mapping_page_url_idx ON icon_mapping(page_url);
      CREATE INDEX icon_mapping_icon_id_idx ON icon_mapping(icon_id);
      \(numbers(10_000)) INSERT INTO favicons SELECT i, 'https://s' || (i / 2) || '.example/' || i || '.ico', 1 FROM n;
      \(numbers(20_000)) INSERT INTO favicon_bitmaps (icon_id, last_updated, image_data, width, height)
        SELECT i / 2, i, randomblob(1500), 16 * (1 + i % 2), 16 * (1 + i % 2) FROM n;
      \(numbers(50_000)) INSERT INTO icon_mapping (page_url, icon_id)
        SELECT 'https://s' || (i % 5000) || '.example/p' || i, (i % 5000) * 2 + ((i / 5000) % 10 >= 7) FROM n;
      """)
  }

  private func history() throws -> URL {
    try database("History", """
      CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL,
        typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
      \(numbers(100_000)) INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time)
        SELECT 'https://s' || (i % 5000) || '.example/h' || i, 'Page ' || i, 1 + i % 7, i % 2, 13400000000000000 + i FROM n;
      """)
  }

  private func encrypt(_ plain: Data) -> Data {
    Data("v10".utf8) + SafeStorage.crypt(CCOperation(kCCEncrypt), plain, key: key)!
  }

  private func insert(_ db: OpaquePointer?, _ sql: String, _ count: Int, _ bind: (OpaquePointer?, Int) -> Void) {
    var statement: OpaquePointer?
    XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
    for index in 0..<count {
      sqlite3_reset(statement)
      bind(statement, index)
      XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
    sqlite3_finalize(statement)
  }

  private func blob(_ statement: OpaquePointer?, _ column: Int32, _ data: Data) {
    _ = data.withUnsafeBytes {
      sqlite3_bind_blob(statement, column, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
  }

  private func cookies() throws -> URL {
    let expiry = Int((now.timeIntervalSince1970 + 11_644_473_600 + 86_400) * 1e6)
    return try database("Cookies", """
      CREATE TABLE meta (key TEXT, value TEXT);
      INSERT INTO meta VALUES ('version', '24');
      CREATE TABLE cookies (host_key TEXT, top_frame_site_key TEXT, name TEXT, value TEXT, encrypted_value BLOB,
        path TEXT, creation_utc INTEGER, expires_utc INTEGER, last_access_utc INTEGER, is_secure INTEGER,
        is_httponly INTEGER, samesite INTEGER, has_expires INTEGER);
      """) { db in
      self.insert(db, "INSERT INTO cookies VALUES (?1, '', ?2, '', ?3, '/', 0, \(expiry), 0, 1, 1, 1, 1)", 10_000) {
        let host = ".s\($1 % 5000).example"
        sqlite3_bind_text($0, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text($0, 2, "c\($1)", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        self.blob($0, 3, self.encrypt(Data(SHA256.hash(data: Data(host.utf8))) + Data("fake-value-\($1)".utf8)))
      }
    }
  }

  private func logins() throws -> URL {
    try database("Login Data", """
      CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER);
      """) { db in
      self.insert(db, "INSERT INTO logins VALUES (?1, 'user', ?2, 0)", 500) {
        sqlite3_bind_text($0, 1, "https://s\($1).example/login", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        self.blob($0, 2, self.encrypt(Data("fake-secret-\($1)".utf8)))
      }
    }
  }

  // 1,500 pages: 500 with their own icon, 500 new pages of known sites and 500 of sites without one.
  private let pages =
    (0..<500).map { URL(string: "https://s\($0).example/p\($0)")! }
    + (500..<1000).map { URL(string: "https://s\($0).example/new")! }
    + (0..<500).map { URL(string: "https://u\($0).example/")! }

  func testAnImportOf15LargeProfiles() throws {
    let files = [try favicons(), try history(), try cookies(), try logins()]
    let profiles = try (0..<15).map { index in
      let folder = home.appending(path: "Profile \(index)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for file in files {
        try FileManager.default.copyItem(at: file, to: folder.appending(path: file.lastPathComponent))
      }
      return folder
    }
    let clock = ContinuousClock()
    var icons: [URL: Data] = [:]
    let faviconTime = try clock.measure {
      icons = ImportedFavicons.read(profiles.map { $0.appending(path: "Favicons") }, pages: pages)
      try ImportedFavicons.save(icons, in: home.appending(path: "Imported Favicons"))
    }
    var counts = (history: 0, cookies: 0, passwords: 0)
    let restTime = try clock.measure {
      for folder in profiles {
        counts.history += try HistoryReader.read(
          HistorySource(browser: "Arc", profile: "", file: folder.appending(path: "History"))).count
        counts.cookies += try LoginsReader.cookies(folder.appending(path: "Cookies"), key: key, now: now).count
        counts.passwords += try LoginsReader.passwords(folder.appending(path: "Login Data"), key: key).count
      }
    }
    print("Import benchmark: favicons \(faviconTime), history, cookies and passwords \(restTime)")
    XCTAssertEqual(icons.count, 1000)
    XCTAssertEqual(counts.history, 1_500_000)
    XCTAssertEqual(counts.cookies, 150_000)
    XCTAssertEqual(counts.passwords, 7500)
  }
}
