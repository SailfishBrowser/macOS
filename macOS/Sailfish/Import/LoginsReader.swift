import CommonCrypto
import CryptoKit
import Foundation
import Security

struct ImportedPassword: Equatable, Sendable {
  var url: String
  var username: String
  var password: String
}

struct ImportedCookie: Equatable, Sendable {
  var name: String
  var value: String
  // With a leading dot for a cookie its subdomains get too.
  var domain: String
  var path: String
  var creation: Date
  // nil for a session cookie.
  var expiry: Date?
  var lastAccess: Date
  var isSecure: Bool
  var isHTTPOnly: Bool
  // As Chromium stores it: -1 unspecified, 0 none, 1 lax, 2 strict.
  var sameSite: Int
}

// How Chromium encrypts passwords and cookies on macOS ("v10"): AES-128-CBC, with a fixed IV of spaces, under a key
// derived from the password the browser keeps in the keychain as "<Name> Safe Storage".
enum SafeStorage {
  // The browser's password from the keychain, which first asks the user to allow it.
  static func password(service: String) throws -> Data {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let password = result as? Data else {
      throw status == errSecItemNotFound ? ImportError.unreadable : ImportError.keychainDenied
    }
    return password
  }

  static func key(password: Data) -> Data {
    let salt = Array("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
    _ = password.withUnsafeBytes { password in
      CCKeyDerivationPBKDF(
        CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress?.assumingMemoryBound(to: CChar.self), password.count, salt,
        salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
    }
    return Data(key)
  }

  // CommonCrypto checks only the last byte of the padding, so a wrong key would often pass; this checks it all.
  static func decrypt(_ value: Data, key: Data) -> Data? {
    guard value.starts(with: Array("v10".utf8)),
      let plain = crypt(CCOperation(kCCDecrypt), value.dropFirst(3), key: key, options: 0),
      let pad = plain.last.map(Int.init), (1...kCCBlockSizeAES128).contains(pad), plain.count >= pad,
      plain.suffix(pad).allSatisfy({ $0 == pad })
    else { return nil }
    return plain.dropLast(pad)
  }

  static func crypt(
    _ operation: CCOperation, _ input: Data, key: Data, options: Int = kCCOptionPKCS7Padding
  ) -> Data? {
    let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
    var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
    var count = 0
    let status = key.withUnsafeBytes { key in
      input.withUnsafeBytes { input in
        CCCrypt(
          operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(options), key.baseAddress, key.count, iv,
          input.baseAddress, input.count, &output, output.count, &count)
      }
    }
    return status == kCCSuccess ? Data(output.prefix(count)) : nil
  }
}

// The passwords and cookies of a Chromium profile, decrypted in memory.
enum LoginsReader {
  // Those saved, not the sites never to save for.
  static func passwords(_ file: URL, key: Data) throws -> [ImportedPassword] {
    try ImportDatabase.rows(
      file, "SELECT origin_url, username_value, password_value FROM logins WHERE blacklisted_by_user = 0"
    ) { row in
      guard let password = SafeStorage.decrypt(row.data(2), key: key).flatMap({ String(data: $0, encoding: .utf8) }),
        !password.isEmpty
      else { return nil }
      return ImportedPassword(url: row.text(0), username: row.text(1), password: password)
    }
  }

  // Those not yet expired, but for partitioned ones, which belong to the site that embedded theirs.
  static func cookies(_ file: URL, key: Data, now: Date) throws -> [ImportedCookie] {
    let query = """
      SELECT host_key, name, value, encrypted_value, path, creation_utc, expires_utc, last_access_utc, is_secure,
        is_httponly, samesite, has_expires, (SELECT value FROM meta WHERE key = 'version')
      FROM cookies WHERE top_frame_site_key = ''
      """
    // Microseconds since 1601.
    func date(_ time: Int) -> Date { Date(timeIntervalSince1970: Double(time) / 1e6 - 11_644_473_600) }
    return try ImportDatabase.rows(file, query) { row in
      let expiry = row.int(11) == 0 ? nil : date(row.int(6))
      if let expiry, expiry < now { return nil }
      var value = Data(row.text(2).utf8)
      if !row.data(3).isEmpty {
        guard let decrypted = SafeStorage.decrypt(row.data(3), key: key) else { return nil }
        // From version 24 a value starts with the SHA-256 of its domain, which tells a wrong key too.
        if (Int(row.text(12)) ?? 0) >= 24 {
          guard decrypted.prefix(32) == Data(SHA256.hash(data: Data(row.text(0).utf8))) else { return nil }
          value = decrypted.dropFirst(32)
        } else {
          value = decrypted
        }
      }
      guard let value = String(data: value, encoding: .utf8) else { return nil }
      return ImportedCookie(
        name: row.text(1), value: value, domain: row.text(0), path: row.text(4), creation: date(row.int(5)),
        expiry: expiry, lastAccess: date(row.int(7)), isSecure: row.int(8) != 0, isHTTPOnly: row.int(9) != 0,
        sameSite: row.int(10))
    }
  }
}

// Safari's Cookies.binarycookies: big-endian pages of little-endian cookie records.
enum SafariCookiesReader {
  static func read(_ file: URL, now: Date) throws -> [ImportedCookie] {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch let error as CocoaError where ImportError.isDenied(error) {
      throw ImportError.needsFullDiskAccess
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    }
    guard let cookies = cookies(Array(data), now: now) else { throw ImportError.unreadable }
    return cookies
  }

  static func cookies(_ bytes: [UInt8], now: Date) -> [ImportedCookie]? {
    func int(_ at: Int, bigEndian: Bool = false) -> Int? {
      guard at >= 0, at + 4 <= bytes.count else { return nil }
      let word = bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
      return Int(bigEndian ? word : word.byteSwapped)
    }
    func date(_ at: Int) -> Date? {
      guard at >= 0, at + 8 <= bytes.count else { return nil }
      let bits = bytes[at..<at + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
      return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
    }
    func string(_ at: Int, _ end: Int) -> String? {
      guard at >= 0, at < end, let stop = bytes[at..<end].firstIndex(of: 0) else { return nil }
      return String(bytes: bytes[at..<stop], encoding: .utf8)
    }
    guard bytes.starts(with: Array("cook".utf8)), let pageCount = int(4, bigEndian: true) else { return nil }
    var page = 8 + pageCount * 4
    var cookies: [ImportedCookie] = []
    for index in 0..<pageCount {
      guard let size = int(8 + index * 4, bigEndian: true), let count = int(page + 4) else { return nil }
      for slot in 0..<count {
        guard let offset = int(page + 8 + slot * 4) else { return nil }
        let start = page + offset
        guard let length = int(start), let flags = int(start + 8), let domainAt = int(start + 16),
          let nameAt = int(start + 20), let pathAt = int(start + 24), let valueAt = int(start + 28),
          let expiry = date(start + 40), let creation = date(start + 48)
        else { return nil }
        let end = min(start + length, bytes.count)
        guard let domain = string(start + domainAt, end), let name = string(start + nameAt, end),
          let path = string(start + pathAt, end), let value = string(start + valueAt, end)
        else { return nil }
        if expiry < now { continue }
        cookies.append(ImportedCookie(
          name: name, value: value, domain: domain, path: path, creation: creation, expiry: expiry,
          lastAccess: creation, isSecure: flags & 1 != 0, isHTTPOnly: flags & 4 != 0, sameSite: -1))
      }
      page += size
    }
    return cookies
  }
}
