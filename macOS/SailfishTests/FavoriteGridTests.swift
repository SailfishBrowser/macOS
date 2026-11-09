import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class FavoriteGridTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)
  let url = URL(string: "https://a.example")!

  // A space whose profile has these favorites, saved in these rows (one row by default), and these Today tabs.
  private func makeSpace(favorites: [Int], rows: [[Int]]? = nil, today: [Int] = []) -> Space {
    @Shared(.profiles) var profiles
    $profiles.withLock { $0 = [Profile(id: UUID(200), name: "Default")] }
    var space = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    space.tabs = IdentifiedArray(
      uniqueElements: favorites.map { tab($0, .favorite) } + today.map { tab($0, .unpinned) })
    space.favoriteRows = (rows ?? [favorites]).map { $0.map { UUID($0) } }
    return space
  }

  private func tab(_ id: Int, _ placement: Placement) -> Tab {
    Tab(
      id: UUID(id), url: url, title: "\(id)", placement: placement, pinnedURL: placement == .unpinned ? nil : url,
      createdAt: now, lastActiveAt: now)
  }

  private func grid(_ space: Space) -> [[UUID]] {
    space.favoriteGrid.map { $0.map(\.id) }
  }

  private func makeStore(_ space: Space) -> TestStoreOf<TabsFeature> {
    let store = TestStore(initialState: space) {
      TabsFeature()
    } withDependencies: {
      $0.date = .constant(now)
    }
    store.exhaustivity = .off
    return store
  }

  func testUpToFourFavoritesShareARowAndMoreWrapAsEvenlyAsTheyGo() {
    let shapes = (1...13).map { makeSpace(favorites: Array(1...$0)).favoriteGrid.map(\.count) }
    XCTAssertEqual(
      shapes,
      [[1], [2], [3], [4], [3, 2], [3, 3], [4, 3], [4, 4], [3, 3, 3], [4, 4, 2], [4, 4, 3], [4, 4, 4], [4, 4, 4, 1]])
  }

  func testRowsSavedByHandFlowIntoTheGridInTheirOrder() {
    // 99 is no longer a favorite, and 4 was never placed.
    let space = makeSpace(favorites: [1, 2, 3, 4], rows: [[3], [1, 99], [2]])
    XCTAssertEqual(grid(space), [[UUID(3), UUID(1), UUID(2), UUID(4)]])
  }

  func testATabDroppedInAFullRowTakesThatPlaceAndTheTilesAfterItFlowOn() async {
    let store = makeStore(makeSpace(favorites: [1, 2, 3, 4], today: [9]))
    await store.send(.moveFavorite(UUID(9), to: 2))
    XCTAssertEqual(store.state.tabs[id: UUID(9)]?.placement, .favorite)
    XCTAssertEqual(grid(store.state), [[UUID(1), UUID(2), UUID(9)], [UUID(3), UUID(4)]])
    XCTAssertEqual(store.state.favoriteRows, [[UUID(1), UUID(2), UUID(9)], [UUID(3), UUID(4)]])
  }

  func testAFavoriteDraggedAlongTheGridLandsWhereItWasDropped() async {
    let store = makeStore(makeSpace(favorites: [1, 2, 3, 4, 5]))
    // The 4th place among the tiles left without it.
    await store.send(.moveFavorite(UUID(1), to: 3))
    XCTAssertEqual(grid(store.state), [[UUID(2), UUID(3), UUID(4)], [UUID(1), UUID(5)]])
  }

  func testAFavoriteAddedFromTheMenuGoesToTheEnd() async {
    let store = makeStore(makeSpace(favorites: [1, 2, 3], rows: [[3], [1, 2]], today: [9]))
    await store.send(.move(UUID(9), .favorite, before: nil))
    XCTAssertEqual(grid(store.state), [[UUID(3), UUID(1), UUID(2), UUID(9)]])
  }

  // Five cells, 3 + 2, in a grid 224 pt wide: tiles 69.3 pt wide and 47 pt tall, 8 pt apart.
  func testTheCellUnderThePointerIsWhereTheDraggedTileGoes() {
    let frame = CGRect(x: 10, y: 100, width: 224, height: 102)
    func index(_ x: CGFloat, _ y: CGFloat) -> Int {
      FavoriteGrid.index(at: CGPoint(x: frame.minX + x, y: frame.minY + y), cells: 5, in: frame)
    }
    XCTAssertEqual(index(20, 20), 0)
    XCTAssertEqual(index(110, 20), 1)
    XCTAssertEqual(index(200, 20), 2)
    XCTAssertEqual(index(20, 70), 3)
    XCTAssertEqual(index(110, 70), 4)
    // The blank after the last tile, and anywhere below the grid, take the last cell.
    XCTAssertEqual(index(200, 70), 4)
    XCTAssertEqual(index(110, 300), 4)
    // Above the grid is its first row.
    XCTAssertEqual(index(110, -20), 1)
    // A gap splits at its middle: the first tile ends at 69.3 and the second starts at 77.3.
    XCTAssertEqual(index(72, 20), 0)
    XCTAssertEqual(index(75, 20), 1)
    // The first row ends at 47 and the second starts at 55.
    XCTAssertEqual(index(20, 50), 0)
    XCTAssertEqual(index(20, 52), 3)
  }

  func testUpToFourCellsShareTheWidth() {
    let frame = CGRect(x: 0, y: 0, width: 224, height: 47)
    func index(_ x: CGFloat, cells: Int) -> Int { FavoriteGrid.index(at: CGPoint(x: x, y: 20), cells: cells, in: frame) }
    XCTAssertEqual(index(200, cells: 1), 0)
    XCTAssertEqual(index(100, cells: 2), 0)
    XCTAssertEqual(index(200, cells: 2), 1)
    XCTAssertEqual(index(120, cells: 4), 2)
    XCTAssertEqual(index(200, cells: 4), 3)
  }
}
