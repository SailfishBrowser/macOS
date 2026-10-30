import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class SpacesFeatureTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)
  let url = URL(string: "https://a.example")!

  func testTurnIntoSpaceCanBeUndone() async {
    var home = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    home.folders = [Folder(id: UUID(10), name: "Work"), Folder(id: UUID(12), name: "Mail")]
    home.tabs = [Tab(id: UUID(50), url: url, title: "A", placement: .folder(UUID(10)), createdAt: now, lastActiveAt: now)]
    home.pinnedOrder = [UUID(10), UUID(50), UUID(12)]
    let store = TestStore(initialState: SpacesFeature.State(spaces: [home], selectedID: home.id)) {
      SpacesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(now)
      $0.webEngine.create = { _, _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
    }
    store.exhaustivity = .off
    let conversion = FolderConversion(
      space: UUID(0), source: UUID(100), rows: [.folder(home.folders[0]), .tab(home.tabs[0])], pinnedOrder: home.pinnedOrder)

    await store.send(.folderToSpace(UUID(10), in: UUID(100)))
    await store.receive(\.delegate.folderTurnedIntoSpace, conversion)
    XCTAssertEqual(store.state.spaces.map(\.id), [UUID(100), UUID(0)])
    XCTAssertEqual(store.state.spaces[0].tree().map(\.id), [UUID(12)])
    // A tab opened in the new space comes back with it.
    await store.send(.spaces(.element(id: UUID(0), action: .open(url))))
    await store.send(.undoFolderToSpace(conversion))
    XCTAssertEqual(store.state.spaces.map(\.id), [UUID(100)])
    XCTAssertEqual(store.state.selectedID, UUID(100))
    XCTAssertEqual(store.state.spaces[0].tree().map(\.id), [UUID(10), UUID(50), UUID(12)])
    XCTAssertEqual(store.state.spaces[0].tabs.map(\.id), [UUID(50), UUID(1)])
    XCTAssertEqual(store.state.spaces[0].tabs[id: UUID(50)]?.placement, .folder(UUID(10)))
    await store.skipReceivedActions()
  }

  func testDeleteClosesItsTabsAndSelectsThePreviousSpace() async {
    let first = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    var second = Space(id: UUID(101), name: "Space 2", profileID: UUID(200), createdAt: now)
    second.tabs = [
      Tab(id: UUID(50), url: url, title: "A", placement: .pinned, createdAt: now, lastActiveAt: now, isLive: true),
      Tab(id: UUID(51), url: url, title: "B", placement: .unpinned, createdAt: now, lastActiveAt: now),
    ]
    let closed = LockIsolated<[UUID]>([])
    let store = TestStore(initialState: SpacesFeature.State(spaces: [first, second], selectedID: second.id)) {
      SpacesFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.webEngine.close = { tab in closed.withValue { $0.append(tab) } }
    }
    @Shared(.archive) var archive

    await store.send(.delete(UUID(101))) {
      $0.spaces.remove(id: UUID(101))
      $0.selectedID = UUID(100)
    }
    var deleted = second
    deleted.tabs[id: UUID(50)]?.isLive = false
    await store.receive(\.delegate.deleted)
    await store.receive(\.spaces[id: UUID(100)].activateAfterSwitch)
    XCTAssertEqual(archive.map(\.id), [UUID(50), UUID(51)])
    await store.send(.delete(UUID(100)))
    await store.finish()
    XCTAssertEqual(closed.value, [UUID(50)])
    // Undo puts it back where it was and takes its tabs out of the archive.
    await store.send(.restore(deleted, at: 1)) {
      $0.spaces.append(deleted)
      $0.selectedID = UUID(101)
    }
    await store.receive(\.spaces[id: UUID(101)].activateAfterSwitch)
    XCTAssertEqual(archive, [])
  }
}
