import ComposableArchitecture
import Foundation

struct Snapshot: Codable, Equatable {
  typealias Migration = @Sendable (inout [String: Any]) throws -> Void

  static let version = 13
  // Each step from an older version, by the version it starts at. Version 13 is the first any release wrote.
  static let migrations: [Int: Migration] = [:]

  var version = Snapshot.version
  var profiles: IdentifiedArrayOf<Profile>
  var archive: IdentifiedArrayOf<ArchivedTab> = []
  var windows: [Window]
  // The window last made key, brought to the front on relaunch.
  var focusedWindow: UUID?

  struct Window: Codable, Equatable {
    let id: UUID
    var frame: CGRect?
    var sidebar: SidebarFeature.State
    var spaces: SpacesFeature.State
  }

  enum Failure: Error, Equatable {
    case unreadable
    case newerVersion(Int)
    case missingMigration(from: Int)
  }

  static func decode(_ data: Data, migrations: [Int: Migration] = migrations) throws -> Snapshot {
    // Not JSON at all reads as unreadable, like JSON that is not a snapshot.
    guard
      var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      var version = json["version"] as? Int
    else { throw Failure.unreadable }
    guard version <= Self.version else { throw Failure.newerVersion(version) }
    while version < Self.version {
      guard let migrate = migrations[version] else { throw Failure.missingMigration(from: version) }
      try migrate(&json)
      version += 1
      json["version"] = version
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }
}
