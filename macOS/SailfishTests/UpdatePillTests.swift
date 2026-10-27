import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class UpdatePillTests: XCTestCase {
  func testUpdateReadyShowsThePillWithItsVersion() async {
    let store = TestStore(initialState: AppFeature.State()) { AppFeature() }

    await store.send(.updateReady("0.1.1")) {
      $0.$readyUpdate.withLock { $0 = "0.1.1" }
    }
  }

  func testRestartInstallsTheUpdate() async {
    let space = Space(id: UUID(1), name: "Home", profileID: UUID(2), createdAt: Date(timeIntervalSince1970: 0))
    let installs = LockIsolated(0)
    let store = TestStore(
      initialState: WindowFeature.State(id: UUID(3), sidebar: .init(), spaces: .init(spaces: [space], selectedID: space.id))
    ) {
      WindowFeature()
    } withDependencies: {
      $0.updates.install = { installs.withValue { $0 += 1 } }
    }

    await store.send(.restartToUpdate)
    XCTAssertEqual(installs.value, 1)
  }
}
