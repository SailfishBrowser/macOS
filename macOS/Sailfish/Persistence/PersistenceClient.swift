import ComposableArchitecture
import Foundation

// A copy of the sidebar state kept beside it, for Restore Data.
struct Backup: Equatable, Identifiable, Sendable {
  let url: URL
  let date: Date

  var id: URL { url }
}

@DependencyClient
struct PersistenceClient: Sendable {
  var load: @Sendable () throws -> Data?
  // Writes the state, and once an hour a backup copy of it.
  var save: @Sendable (Data) throws -> Void
  // Writes a backup copy now, as before a restore.
  var backup: @Sendable (Data) throws -> Void
  // The backups kept, newest first.
  var backups: @Sendable () throws -> [Backup] = { [] }
  var loadBackup: @Sendable (Backup) throws -> Data
  // Moves a state file that does not read to State.json.unreadable, so a save cannot overwrite it.
  var setAside: @Sendable () throws -> Void = {}
}

extension PersistenceClient: DependencyKey {
  static let liveValue: Self = {
    let url = URL.dataDirectory.appending(path: "State.json")
    return Self(
      load: { FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil },
      save: { data in
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if try Backups.list().first.map({ Date.now.timeIntervalSince($0.date) >= Backups.interval }) ?? true {
          try Backups.write(data)
        }
      },
      backup: { data in try Backups.write(data) },
      backups: { try Backups.list() },
      loadBackup: { backup in try Data(contentsOf: backup.url) },
      setAside: {
        let aside = url.appendingPathExtension("unreadable")
        if FileManager.default.fileExists(atPath: aside.path) {
          try FileManager.default.removeItem(at: aside)
        }
        try FileManager.default.moveItem(at: url, to: aside)
      }
    )
  }()
  static let testValue = Self()
}

// The rotation of sidebar backups: up to ten from today, one a day for ten days, one a week for ten weeks,
// then one a month for a year.
enum Backups {
  static let directory = URL.dataDirectory.appending(path: "Backups")
  static let interval: TimeInterval = 3600

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
    return formatter
  }()

  static func list() throws -> [Backup] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    return files.compactMap { file in
      formatter.date(from: file.deletingPathExtension().lastPathComponent).map { Backup(url: file, date: $0) }
    }
    .sorted { $0.date > $1.date }
  }

  static func write(_ data: Data) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appending(path: formatter.string(from: .now) + ".json"), options: .atomic)
    let backups = try list()
    let kept = kept(backups, now: .now)
    for backup in backups where !kept.contains(backup.id) {
      try FileManager.default.removeItem(at: backup.url)
    }
  }

  // The backups the rotation keeps: newest first, the ten newest of today, then the newest of each earlier
  // day, week and month within their spans.
  static func kept(_ backups: [Backup], now: Date, calendar: Calendar = .current) -> Set<Backup.ID> {
    var kept: Set<Backup.ID> = []
    var seen: Set<String> = []
    let today = calendar.startOfDay(for: now)
    for backup in backups.sorted(by: { $0.date > $1.date }) {
      let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: backup.date), to: today).day!
      let bucket: String
      switch days {
      case ..<1:
        guard kept.count < 10 else { continue }
        bucket = "today \(backup.id)"
      case ..<11: bucket = "day \(days)"
      case ..<81: bucket = "week \(days / 7)"
      case ..<446: bucket = "month \(days / 30)"
      default: continue
      }
      if seen.insert(bucket).inserted {
        kept.insert(backup.id)
      }
    }
    return kept
  }
}

extension URL {
  // Separate for Debug and Release builds (project.yml).
  static let dataDirectory = applicationSupportDirectory.appending(
    path: Bundle.main.object(forInfoDictionaryKey: "DataFolder") as! String)
}

extension DependencyValues {
  var persistence: PersistenceClient {
    get { self[PersistenceClient.self] }
    set { self[PersistenceClient.self] = newValue }
  }
}
