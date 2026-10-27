import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class LittleSailfishFeatureTests: XCTestCase {
  let url = URL(string: "https://example.com/")!

  // A click outside the editor and Escape both dismiss it.
  func testDismissingTheURLEditorKeepsThePageURLWithoutLoading() async {
    let now = Date(timeIntervalSince1970: 1_000)
    let tab = Tab(id: UUID(50), url: url, title: "Example", placement: .unpinned, createdAt: now, lastActiveAt: now)
    let store = TestStore(initialState: LittleSailfishFeature.State(id: UUID(1), profileID: UUID(200), tab: tab)) {
      LittleSailfishFeature()
    } withDependencies: {
      $0.autocomplete.query = { _, _, _, _, _ in .finished }
    }
    store.exhaustivity = .off

    await store.send(.editURL)
    XCTAssertEqual(store.state.commandBar?.query, url.absoluteString)
    await store.send(.commandBar(.presented(.queryChanged("other.example"))))
    await store.send(.commandBar(.dismiss)) { $0.commandBar = nil }
    XCTAssertEqual(store.state.tab?.url, url)
  }

  // The editor's X clears the field and leaves the editor open.
  func testTheURLEditorsCloseButtonClearsTheField() async {
    let now = Date(timeIntervalSince1970: 1_000)
    let tab = Tab(id: UUID(50), url: url, title: "Example", placement: .unpinned, createdAt: now, lastActiveAt: now)
    let store = TestStore(initialState: LittleSailfishFeature.State(id: UUID(1), profileID: UUID(200), tab: tab)) {
      LittleSailfishFeature()
    } withDependencies: {
      $0.autocomplete.query = { _, _, _, _, _ in .finished }
    }
    store.exhaustivity = .off

    await store.send(.editURL)
    await store.send(.commandBar(.presented(.queryChanged(""))))
    XCTAssertEqual(store.state.commandBar?.query, "")
    XCTAssertEqual(store.state.tab?.url, url)
  }

  func testDismissingTheCommandBarOfABlankLittleSailfishClosesIt() async {
    let store = TestStore(initialState: LittleSailfishFeature.State(id: UUID(1), profileID: UUID(200))) {
      LittleSailfishFeature()
    }
    store.exhaustivity = .off

    await store.send(.commandBar(.dismiss)) { $0.commandBar = nil }
    await store.receive(\.delegate.close)
  }
}
