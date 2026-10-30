import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class MediaFirstLaunchTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000_000)

  private func appStore(load: Data?) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(now)
      $0.continuousClock = ImmediateClock()
      $0.persistence.load = { load }
      $0.persistence.save = { _ in }
      $0.webEngine.saveSessions = {}
      $0.webEngine.keepSessions = { _ in }
      $0.webEngine.events = { .finished }
      $0.webEngine.create = { _, _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
      $0.browserImport.isDefaultBrowser = { false }
    }
    store.exhaustivity = .off
    return store
  }

  private func snapshot(spacesCreatedAt dates: [Date]) throws -> Data {
    let spaces = dates.enumerated().map { Space(id: UUID($0), name: "Space", profileID: UUID(200), createdAt: $1) }
    return try Snapshot(
      profiles: [Profile(id: UUID(200), name: "Default")], archive: [],
      windows: [
        Snapshot.Window(
          id: UUID(300), frame: nil, sidebar: .init(),
          spaces: .init(spaces: IdentifiedArray(uniqueElements: spaces), selectedID: spaces[0].id))
      ],
      focusedWindow: nil
    ).encoded()
  }

  func testAFirstLaunchRecordsItsDate() async {
    let store = appStore(load: nil)
    await store.send(.launched)
    await store.receive(\.loaded.success)
    XCTAssertEqual(store.state.firstLaunch, now)
  }

  func testALaterLaunchKeepsTheFirstLaunch() async throws {
    @Shared(.firstLaunch) var firstLaunch
    $firstLaunch.withLock { $0 = now - 86_400 }
    let store = appStore(load: try snapshot(spacesCreatedAt: [now - 3_600]))
    await store.send(.launched)
    await store.receive(\.loaded.success)
    XCTAssertEqual(store.state.firstLaunch, now - 86_400)
  }

  func testAnInstallFromBeforeTheFirstLaunchWasRecordedTakesItsOldestSpace() async throws {
    let store = appStore(load: try snapshot(spacesCreatedAt: [now - 3_600, now - 7_200]))
    await store.send(.launched)
    await store.receive(\.loaded.success)
    XCTAssertEqual(store.state.firstLaunch, now - 7_200)
  }

  func testAWipedDataFolderIsANewFirstLaunch() async {
    @Shared(.firstLaunch) var firstLaunch
    $firstLaunch.withLock { $0 = now - 86_400 }
    let store = appStore(load: nil)
    await store.send(.launched)
    await store.receive(\.loaded.success)
    XCTAssertEqual(store.state.firstLaunch, now)
  }
}
