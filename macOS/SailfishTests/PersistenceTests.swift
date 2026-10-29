import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class PersistenceTests: XCTestCase {
  let fixture = Data(
    """
    {
      "version": 1,
      "windows": [{
        "id": "00000000-0000-0000-0000-000000000300",
        "frame": [[100, 100], [1200, 800]],
        "sidebar": { "isFloating": true, "showsFavoritesHint": false },
        "spaces": {
          "selectedID": "00000000-0000-0000-0000-000000000100",
          "spaces": [{
            "id": "00000000-0000-0000-0000-000000000100",
            "name": "Work",
            "profileID": "00000000-0000-0000-0000-000000000200",
            "createdAt": "1970-01-01T00:16:40Z",
            "folders": [],
            "selectedTabID": "00000000-0000-0000-0000-000000000050",
            "tabs": [{
              "id": "00000000-0000-0000-0000-000000000050",
              "url": "https://a.example",
              "title": "A",
              "placement": { "pinned": {} },
              "createdAt": "1970-01-01T00:16:40Z",
              "lastActiveAt": "1970-01-01T00:16:40Z"
            }]
          }]
        }
      }]
    }
    """.utf8)

  func testRestoresSnapshotAndSavesAfterDebounce() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let clock = TestClock()
    let saved = LockIsolated<Data?>(nil)
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.persistence.load = { [fixture] in fixture }
      $0.persistence.save = { data in saved.setValue(data) }
      $0.webEngine.saveSessions = {}
      $0.webEngine.keepSessions = { _ in }
      $0.webEngine.events = { .finished }
      $0.webEngine.create = { _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
    }
    let space = Space(
      id: UUID(0x100), name: "Work", profileID: UUID(0x200), createdAt: now,
      ownTabs: [Tab(id: UUID(0x50), url: URL(string: "https://a.example")!, title: "A", placement: .pinned,
        pinnedURL: URL(string: "https://a.example")!, createdAt: now, lastActiveAt: now)],
      selectedTabID: UUID(0x50), icon: Space.primaryIcon
    )

    await store.send(.launched)
    await store.receive(\.loaded.success) {
      $0.$profiles.withLock { $0 = [Profile(id: UUID(0x200), name: "Default")] }
      $0.windows = [
        WindowFeature.State(
          id: UUID(0x300), frame: CGRect(x: 100, y: 100, width: 1200, height: 800),
          sidebar: SidebarFeature.State(isFloating: true, showsFavoritesHint: false),
          spaces: SpacesFeature.State(spaces: [space], selectedID: space.id)
        )
      ]
      $0.isLoaded = true
      $0.pendingURLs = nil
      $0.$firstLaunch.withLock { $0 = now }
      $0.$mediaFoldersAsked.withLock { $0 = true }
    }
    await store.receive(\.windows[id: UUID(0x300)].spaces.spaces[id: UUID(0x100)].activate) {
      $0.windows[id: UUID(0x300)]?.spaces.spaces[id: UUID(0x100)]?.tabs[id: UUID(0x50)]?.isLive = true
    }
    XCTAssertNil(saved.value)
    await clock.advance(by: .seconds(1))
    let restored = try Snapshot.decode(XCTUnwrap(saved.value))
    XCTAssertEqual(restored, try Snapshot.decode(fixture))
  }

  func testUnreadableStateIsRecoveredFromTheNewestBackupWithTodayTabsGathered() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let today = String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "\"pinned\": {}", with: "\"unpinned\": {}")
    let backups = [
      Backup(url: URL(filePath: "/backups/new.json"), date: now),
      Backup(url: URL(filePath: "/backups/old.json"), date: now - 3600),
    ]
    let setAside = LockIsolated(false)
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(now)
      $0.continuousClock = ImmediateClock()
      $0.persistence.load = { Data("not json".utf8) }
      $0.persistence.save = { _ in }
      $0.webEngine.saveSessions = {}
      $0.webEngine.keepSessions = { _ in }
      $0.persistence.setAside = { setAside.setValue(true) }
      $0.persistence.backups = { backups }
      $0.persistence.loadBackup = { $0 == backups[0] ? Data(today.utf8) : Data() }
      $0.webEngine.events = { .finished }
      $0.webEngine.create = { _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.launched)
    await store.receive(\.recovered)
    let space = try XCTUnwrap(store.state.windows[id: UUID(0x300)]?.spaces.spaces[id: UUID(0x100)])
    XCTAssertEqual(space.folders.map(\.name), ["Recently recovered"])
    XCTAssertEqual(space.tabs[id: UUID(0x50)]?.placement, .folder(space.folders[0].id))
    XCTAssertEqual(space.tabs[id: UUID(0x50)]?.pinnedURL, URL(string: "https://a.example"))
    XCTAssertTrue(store.state.isLoaded)
    // The file that did not read was moved aside before any save.
    XCTAssertTrue(setAside.value)
  }

  func testBackupRotationKeepsTenOfTodayThenOneADayWeekAndMonth() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    // 22:13 UTC, so every backup from the last ten hours is from today.
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func backup(_ hoursAgo: Double) -> Backup {
      Backup(url: URL(filePath: "/backups/\(hoursAgo).json"), date: now - hoursAgo * 3600)
    }
    let todays = (0..<12).map { backup(Double($0) * 0.5) }
    let yesterday = [backup(30), backup(40)]
    let lastWeek = [backup(24 * 12), backup(24 * 13)]
    let lastYear = [backup(24 * 400)]
    let tooOld = [backup(24 * 500)]
    let kept = Backups.kept(todays + yesterday + lastWeek + lastYear + tooOld, now: now, calendar: calendar)
    XCTAssertEqual(kept, Set((todays.prefix(10) + [yesterday[0], lastWeek[0], lastYear[0]]).map(\.id)))
  }

  func testNewerVersionIsNotRestoredOrOverwritten() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.persistence.load = { Data(#"{"version": 99, "windows": []}"#.utf8) }
      $0.webEngine.events = { .finished }
    }
    store.exhaustivity = .off

    await store.send(.launched)
    await store.receive(\.loaded.failure)
    XCTAssertEqual(store.state.windows.count, 1)
    XCTAssertFalse(store.state.isLoaded)
    XCTAssertNil(store.state.snapshot)
  }

  func testVersion1MigrationAddsAProfilePerDistinctSpaceProfile() throws {
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
    var windows = try XCTUnwrap(json["windows"] as? [[String: Any]])
    var second = windows[0]
    var spaces = try XCTUnwrap(second["spaces"] as? [String: Any])
    var list = try XCTUnwrap(spaces["spaces"] as? [[String: Any]])
    list.append(list[0])
    list[1]["id"] = UUID(0x101).uuidString
    list[1]["profileID"] = UUID(0x201).uuidString
    spaces["spaces"] = list
    second["spaces"] = spaces
    second["id"] = UUID(0x301).uuidString
    windows.append(second)
    json["windows"] = windows

    let migrated = try Snapshot.decode(JSONSerialization.data(withJSONObject: json))
    let migratedSpaces = migrated.windows.flatMap(\.spaces.spaces)
    XCTAssertEqual(migrated.profiles, [Profile(id: UUID(0x200), name: "Default"), Profile(id: UUID(0x201), name: "Profile 2")])
    XCTAssertEqual(migratedSpaces.map(\.profileID), [UUID(0x200), UUID(0x200), UUID(0x201)])
    XCTAssertEqual(migratedSpaces.map(\.icon), [Space.primaryIcon, Space.primaryIcon, ""])
    XCTAssertEqual(migratedSpaces.map(\.theme), Array(repeating: SpaceTheme(), count: 3))
    XCTAssertEqual(migratedSpaces.map(\.splits), [[], [], []])
    XCTAssertEqual(migratedSpaces.map(\.groups), [[], [], []])
  }

  func testMigrationsRunInOrderUpToCurrentVersion() throws {
    let legacy = Data(#"{"version": 0, "windowList": []}"#.utf8)
    let migrated = try Snapshot.decode(legacy, migrations: [
      0: { json in json["windows"] = json.removeValue(forKey: "windowList") },
      1: Snapshot.migrations[1]!,
      2: Snapshot.migrations[2]!,
      3: Snapshot.migrations[3]!,
      4: Snapshot.migrations[4]!,
      5: Snapshot.migrations[5]!,
      6: Snapshot.migrations[6]!,
      7: Snapshot.migrations[7]!,
      8: Snapshot.migrations[8]!,
      9: Snapshot.migrations[9]!,
      10: Snapshot.migrations[10]!,
      11: Snapshot.migrations[11]!,
      12: Snapshot.migrations[12]!,
    ])
    XCTAssertEqual(migrated, Snapshot(profiles: [], windows: []))
    XCTAssertThrowsError(try Snapshot.decode(legacy, migrations: [:])) {
      XCTAssertEqual($0 as? Snapshot.Failure, .missingMigration(from: 0))
    }
  }

  func testVersion10MigrationMovesFavoritesToTheirProfileOnePerURL() throws {
    func tab(_ n: Int, _ url: String, favorite: Bool = true) -> [String: Any] {
      ["id": UUID(n).uuidString, "url": url, "pinnedURL": url, "placement": favorite ? ["favorite": [:]] : ["unpinned": [:]]]
    }
    func space(_ profile: Int, tabs: [[String: Any]], rows: [[Int]], selected: Int) -> [String: Any] {
      [
        "profileID": UUID(profile).uuidString, "tabs": tabs, "favoriteRows": rows.map { $0.map { UUID($0).uuidString } },
        "selectedTabID": UUID(selected).uuidString,
      ]
    }
    var json: [String: Any] = [
      "profiles": [["id": UUID(1).uuidString], ["id": UUID(2).uuidString]],
      "windows": [["spaces": ["spaces": [
        space(1, tabs: [tab(10, "https://a.example"), tab(11, "https://b.example"), tab(12, "https://c.example", favorite: false)], rows: [[10, 11]], selected: 12),
        space(1, tabs: [tab(20, "https://b.example"), tab(21, "https://d.example")], rows: [[21], [20]], selected: 20),
        space(2, tabs: [tab(30, "https://a.example")], rows: [], selected: 30),
      ]]]],
    ]
    try Snapshot.migrations[10]!(&json)
    let profiles = json["profiles"] as! [[String: Any]]
    let spaces = ((json["windows"] as! [[String: Any]])[0]["spaces"] as! [String: Any])["spaces"] as! [[String: Any]]
    func ids(_ tabs: Any?) -> [String] { (tabs as! [[String: Any]]).map { $0["id"] as! String } }
    // The second space's b.example is the first's, and its rows follow the first's.
    XCTAssertEqual(ids(profiles[0]["favorites"]), [10, 11, 21].map { UUID($0).uuidString })
    XCTAssertEqual(profiles[0]["favoriteRows"] as? [[String]], [[10, 11], [21]].map { $0.map { UUID($0).uuidString } })
    XCTAssertEqual(ids(profiles[1]["favorites"]), [UUID(30).uuidString])
    XCTAssertEqual(profiles[1]["favoriteRows"] as? [[String]], [])
    XCTAssertEqual(spaces.map { ids($0["tabs"]) }, [[UUID(12).uuidString], [], []])
    XCTAssertEqual(spaces.map { $0["favoriteRows"] == nil }, [true, true, true])
    // The second space showed the dropped duplicate, so it shows the kept one.
    XCTAssertEqual(spaces.map { $0["selectedTabID"] as? String }, [12, 11, 30].map { UUID($0).uuidString })
  }

  func testVersion12MigrationGivesEachWindowsFirstSpaceThePrimaryIconUnlessItHasOne() throws {
    var json: [String: Any] = ["windows": [
      ["spaces": ["spaces": [["icon": ""], ["icon": ""]]]],
      ["spaces": ["spaces": [["icon": "🐟"], ["icon": ""]]]],
      ["spaces": ["spaces": [[String: Any]]()]],
    ]]
    try Snapshot.migrations[12]!(&json)
    let icons = (json["windows"] as! [[String: Any]]).map {
      (($0["spaces"] as! [String: Any])["spaces"] as! [[String: Any]]).map { $0["icon"] as! String }
    }
    XCTAssertEqual(icons, [[Space.primaryIcon, ""], ["🐟", ""], []])
  }

  func testVersion8MigrationLaysFavoritesOutInEvenRowsOfThree() throws {
    let favorites = (1...5).map { ["id": UUID($0).uuidString, "placement": ["favorite": [:]]] as [String: Any] }
    var json: [String: Any] = ["windows": [["spaces": ["spaces": [["tabs": favorites + [["id": UUID(9).uuidString, "placement": ["unpinned": [:]]]]]]]]]]
    try Snapshot.migrations[8]!(&json)
    let space = try XCTUnwrap((((json["windows"] as? [[String: Any]])?[0]["spaces"] as? [String: Any])?["spaces"] as? [[String: Any]])?[0])
    XCTAssertEqual(space["favoriteRows"] as? [[String]], [[1, 2, 3], [4, 5]].map { $0.map { UUID($0).uuidString } })
  }
}
