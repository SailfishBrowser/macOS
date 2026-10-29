import Foundation
import SQLite3

// A browser profile's history database.
struct HistorySource: Equatable, Hashable, Identifiable, Sendable {
  var browser: String
  var profile: String
  var file: URL

  var id: URL { file }
  var title: String { profile.isEmpty ? browser : "\(browser) – \(profile)" }
}

struct HistoryRecord: Equatable, Sendable {
  var url: String
  var title: String
  var visitCount: Int
  var typedCount: Int
  var lastVisit: Date
}

enum ImportError: Error, Equatable {
  // macOS keeps Safari's data from apps without Full Disk Access.
  case needsFullDiskAccess
  // The user didn't allow the browser's Safe Storage key in the keychain prompt.
  case keychainDenied
  case unreadable

  static func isDenied(_ error: CocoaError) -> Bool {
    error.code == .fileReadNoPermission || (error.underlying as? POSIXError)?.code == .EPERM
  }
}

enum HistoryReader {
  static func read(_ source: HistorySource) throws -> [HistoryRecord] {
    // Columns: URL, title, visit count, typed count, last visit in seconds since 1970.
    let query =
      source.browser == "Safari"
      ? """
      SELECT i.url, v.title, i.visit_count, 0, MAX(v.visit_time) + 978307200
      FROM history_items i JOIN history_visits v ON v.history_item = i.id GROUP BY i.id
      """
      : "SELECT url, title, visit_count, typed_count, last_visit_time / 1e6 - 11644473600 FROM urls WHERE hidden = 0"
    return try ImportDatabase.rows(source.file, query) { row in
      HistoryRecord(
        url: row.text(0), title: row.text(1), visitCount: row.int(2), typedCount: row.int(3),
        lastVisit: Date(timeIntervalSince1970: row.double(4)))
    }
  }
}

// A browser's SQLite database, read from a copy, as the browser may be using it.
enum ImportDatabase {
  struct Row {
    let statement: OpaquePointer

    func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func data(_ column: Int32) -> Data {
      sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, column))) }
        ?? Data()
    }
  }

  static func withCopy<T>(of file: URL, _ body: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let copy = dir.appending(path: file.lastPathComponent)
    do {
      for suffix in ["", "-journal", "-wal"] {
        let file = URL(filePath: file.path + suffix)
        if suffix.isEmpty || FileManager.default.fileExists(atPath: file.path) {
          try FileManager.default.copyItem(at: file, to: URL(filePath: copy.path + suffix))
        }
      }
    } catch let error as CocoaError where ImportError.isDenied(error) {
      throw ImportError.needsFullDiskAccess
    }
    return try body(copy)
  }

  // The rows the query gives that `row` makes something of.
  static func rows<T>(_ file: URL, _ query: String, _ row: (Row) -> T?) throws -> [T] {
    try withCopy(of: file) { try rows(copy: $0, query, row) }
  }

  static func rows<T>(copy: URL, _ query: String, _ row: (Row) -> T?) throws -> [T] {
    var db: OpaquePointer?
    var statement: OpaquePointer?
    defer {
      sqlite3_finalize(statement)
      sqlite3_close(db)
    }
    guard sqlite3_open(copy.path, &db) == SQLITE_OK, sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK
    else { throw ImportError.unreadable }
    var rows: [T] = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      if let made = row(Row(statement: statement!)) { rows.append(made) }
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { throw ImportError.unreadable }
    return rows
  }
}
