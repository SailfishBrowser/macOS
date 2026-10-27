import CommonCrypto
import CryptoKit
import SQLite3
import XCTest

@testable import Sailfish

// Synthetic profiles only: fake passwords and cookies, encrypted with a test key.
final class LoginsReaderTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let key = SafeStorage.key(password: Data("test-password".utf8))
  var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: folder)
  }

  private func encrypt(_ plain: Data) -> String {
    hex(Data("v10".utf8) + SafeStorage.crypt(CCOperation(kCCEncrypt), plain, key: key)!)
  }

  private func hex(_ data: Data) -> String { "X'" + data.map { String(format: "%02x", $0) }.joined() + "'" }

  private func database(_ name: String, _ sql: String) throws -> URL {
    let file = folder.appending(path: name)
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    return file
  }

  // Microseconds since 1601.
  private func chromiumTime(_ date: Date) -> Int { Int((date.timeIntervalSince1970 + 11_644_473_600) * 1e6) }

  func testTheKeyIsDerivedAsChromiumDerivesIt() {
    // Chromium's known answer for PBKDF2-HMAC-SHA1("mock_password", "saltysalt", 1003), in keychain_key_provider_unittest.
    let expected: [UInt8] = [0xAF, 0x0F, 0x76, 0x2A, 0xAF, 0x6D, 0x7D, 0x11, 0x58, 0x1B, 0x7A, 0xA8, 0xCE, 0x72, 0x18, 0xDE]
    XCTAssertEqual(SafeStorage.key(password: Data("mock_password".utf8)), Data(expected))
  }

  func testSavedPasswordsAreDecryptedAndOthersLeftOut() throws {
    let file = try database("Login Data", """
      CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER);
      INSERT INTO logins VALUES ('https://a.example/login', 'alice', \(encrypt(Data("fake-secret-1".utf8))), 0);
      INSERT INTO logins VALUES ('https://b.example/', '', \(encrypt(Data())), 1);
      INSERT INTO logins VALUES ('https://c.example/', 'carol', \(hex(Data("v11garbage".utf8))), 0);
      """)
    XCTAssertEqual(try LoginsReader.passwords(file, key: key), [
      ImportedPassword(url: "https://a.example/login", username: "alice", password: "fake-secret-1"),
    ])
    let other = SafeStorage.key(password: Data("another-browser".utf8))
    XCTAssertEqual(try LoginsReader.passwords(file, key: other), [])
  }

  func testCookiesDropTheirDomainHashFromVersion24AndSkipExpiredAndPartitionedOnes() throws {
    let created = now.addingTimeInterval(-100)
    let expires = now.addingTimeInterval(3_600)
    func row(_ host: String, _ name: String, _ plain: String, _ encrypted: Data?, expiry: Date?, partition: String = "")
      -> String {
      let value = encrypted.map { encrypt(Data(SHA256.hash(data: Data(host.utf8))) + $0) } ?? "X''"
      return """
        INSERT INTO cookies VALUES ('\(host)', '\(partition)', '\(name)', '\(plain)', \(value), '/', \
        \(chromiumTime(created)), \(expiry.map(chromiumTime) ?? 0), \(chromiumTime(created)), 1, 1, 1, \
        \(expiry == nil ? 0 : 1));
        """
    }
    let file = try database("Cookies", """
      CREATE TABLE meta (key TEXT, value TEXT);
      INSERT INTO meta VALUES ('version', '24');
      CREATE TABLE cookies (host_key TEXT, top_frame_site_key TEXT, name TEXT, value TEXT, encrypted_value BLOB,
        path TEXT, creation_utc INTEGER, expires_utc INTEGER, last_access_utc INTEGER, is_secure INTEGER,
        is_httponly INTEGER, samesite INTEGER, has_expires INTEGER);
      \(row(".a.example", "session", "", Data("fake-token".utf8), expiry: expires))
      \(row("b.example", "plain", "fake-plain", nil, expiry: nil))
      \(row("c.example", "old", "", Data("x".utf8), expiry: now.addingTimeInterval(-1)))
      \(row("d.example", "embedded", "", Data("x".utf8), expiry: expires, partition: "https://e.example"))
      """)
    let other = SafeStorage.key(password: Data("another-browser".utf8))
    XCTAssertEqual(try LoginsReader.cookies(file, key: other, now: now).map(\.name), ["plain"])
    let cookies = try LoginsReader.cookies(file, key: key, now: now)
    XCTAssertEqual(cookies.map(\.name), ["session", "plain"])
    XCTAssertEqual(cookies.map(\.value), ["fake-token", "fake-plain"])
    XCTAssertEqual(cookies[0].domain, ".a.example")
    XCTAssertEqual(cookies[0].expiry!.timeIntervalSince1970, expires.timeIntervalSince1970, accuracy: 0.001)
    XCTAssertNil(cookies[1].expiry)
    XCTAssertEqual(cookies[0].creation.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 0.001)
    XCTAssertTrue(cookies[0].isSecure && cookies[0].isHTTPOnly)
    XCTAssertEqual(cookies[0].sameSite, 1)
  }

  func testSafariBinaryCookiesAreRead() throws {
    func le32(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(value).littleEndian, Array.init) }
    func be32(_ value: Int) -> [UInt8] { withUnsafeBytes(of: UInt32(value).bigEndian, Array.init) }
    func date(_ date: Date) -> [UInt8] {
      withUnsafeBytes(of: date.timeIntervalSinceReferenceDate.bitPattern.littleEndian, Array.init)
    }
    func cookie(_ domain: String, _ name: String, _ value: String, flags: Int, expiry: Date) -> [UInt8] {
      let strings = [domain, name, "/", value].map { Array($0.utf8) + [0] }
      var offsets: [Int] = []
      var at = 56
      for string in strings {
        offsets.append(at)
        at += string.count
      }
      let header = le32(at) + le32(0) + le32(flags) + le32(0) + offsets.flatMap(le32) + le32(0) + le32(0)
      return header + date(expiry) + date(now) + strings.flatMap { $0 }
    }
    let records = [
      cookie(".a.example", "sid", "fake-safari", flags: 5, expiry: now.addingTimeInterval(60)),
      cookie("b.example", "gone", "x", flags: 0, expiry: now.addingTimeInterval(-60)),
    ]
    let headerSize = 8 + records.count * 4 + 4
    var offsets: [Int] = []
    var at = headerSize
    for record in records {
      offsets.append(at)
      at += record.count
    }
    let page = [0, 0, 1, 0] + le32(records.count) + offsets.flatMap(le32) + le32(0) + records.flatMap { $0 }
    let bytes = Array("cook".utf8) + be32(1) + be32(page.count) + page
    let file = folder.appending(path: "Cookies.binarycookies")
    try Data(bytes).write(to: file)

    XCTAssertEqual(try SafariCookiesReader.read(file, now: now), [
      ImportedCookie(
        name: "sid", value: "fake-safari", domain: ".a.example", path: "/", creation: now,
        expiry: now.addingTimeInterval(60), lastAccess: now, isSecure: true, isHTTPOnly: true, sameSite: -1),
    ])
    XCTAssertEqual(try SafariCookiesReader.read(folder.appending(path: "None.binarycookies"), now: now), [])
    try Data("cook".utf8).write(to: file)
    XCTAssertThrowsError(try SafariCookiesReader.read(file, now: now))
  }
}
