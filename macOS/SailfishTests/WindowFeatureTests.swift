import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class WindowFeatureTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)

  func testTheURLToolbarIsOffUntilToggledAndReachesEveryWindow() async {
    let home = Space(id: UUID(1), name: "Home", profileID: UUID(200), createdAt: now)
    let window = WindowFeature.State(id: UUID(3), sidebar: .init(), spaces: .init(spaces: [home], selectedID: home.id))
    let other = WindowFeature.State(id: UUID(4), sidebar: .init(), spaces: .init(spaces: [home], selectedID: home.id))
    XCTAssertFalse(window.showsURLToolbar)
    let store = TestStore(initialState: window) { WindowFeature() }

    await store.send(.toggleURLToolbar) { $0.$showsURLToolbar.withLock { $0 = true } }
    XCTAssertTrue(other.showsURLToolbar)

    await store.send(.toggleURLToolbar) { $0.$showsURLToolbar.withLock { $0 = false } }
    XCTAssertFalse(other.showsURLToolbar)
  }

  func testOpeningARowFromTheLibraryClosesItOnThatSpaceAndTab() async {
    let home = Space(id: UUID(1), name: "Home", profileID: UUID(200), createdAt: now)
    var work = Space(id: UUID(2), name: "Work", profileID: UUID(200), createdAt: now)
    work.tabs = [
      Tab(id: UUID(50), url: URL(string: "https://a.example")!, title: "A", placement: .pinned, createdAt: now, lastActiveAt: now)
    ]
    var state = WindowFeature.State(id: UUID(3), sidebar: .init(), spaces: .init(spaces: [home, work], selectedID: home.id))
    state.library = LibraryFeature.State(pane: .spaces)
    state.isLibraryOpen = true
    let store = TestStore(initialState: state) {
      WindowFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.webEngine.create = { _, _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.openFromLibrary(UUID(2), tab: UUID(50))) { $0.isLibraryOpen = false }
    await store.skipReceivedActions()
    XCTAssertEqual(store.state.spaces.selectedID, UUID(2))
    XCTAssertEqual(store.state.spaces.selected.selectedTabID, UUID(50))
  }
}
