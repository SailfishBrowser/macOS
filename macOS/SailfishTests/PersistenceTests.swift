import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class PersistenceTests: XCTestCase {
  let fixture = Data(
    """
    {
      "version": 13,
      "profiles": [{
        "id": "00000000-0000-0000-0000-000000000200",
        "name": "Default",
        "archiveAfter": 43200,
        "favorites": [],
        "favoriteRows": []
      }],
      "archive": [],
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
            "icon": "sail",
            "theme": { "colors": [], "grain": 0, "intensity": 0.8 },
            "folders": [],
            "splits": [],
            "groups": [],
            "pinnedOrder": [],
            "isPinnedCollapsed": false,
            "isHeaderHidden": false,
            "selectedTabID": "00000000-0000-0000-0000-000000000050",
            "tabs": [{
              "id": "00000000-0000-0000-0000-000000000050",
              "url": "https://a.example",
              "title": "A",
              "placement": { "pinned": {} }, "pinnedURL": "https://a.example",
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
      $0.webEngine.create = { _, _, _ in }
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
    let today = String(decoding: fixture, as: UTF8.self).replacingOccurrences(
      of: #""pinned": {} }, "pinnedURL": "https://a.example""#, with: #""unpinned": {} }"#)
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
      $0.webEngine.create = { _, _, _ in }
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

  func testMigrationsRunInOrderUpToCurrentVersion() throws {
    let legacy = Data(#"{"version": 12, "profiles": [], "archive": [], "windowList": []}"#.utf8)
    let migrated = try Snapshot.decode(legacy, migrations: [
      12: { json in json["windows"] = json.removeValue(forKey: "windowList") },
    ])
    XCTAssertEqual(migrated, Snapshot(profiles: [], windows: []))
    XCTAssertThrowsError(try Snapshot.decode(legacy, migrations: [:])) {
      XCTAssertEqual($0 as? Snapshot.Failure, .missingMigration(from: 12))
    }
  }
}
