import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class TabGroupsTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)
  let url = URL(string: "https://a.example")!

  private func space(_ tabs: Int..., group: [Int] = [], selected: Int? = nil) -> Space {
    var space = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    space.tabs = IdentifiedArray(uniqueElements: tabs.map {
      Tab(id: UUID($0), url: url, title: "\($0)", placement: .unpinned, createdAt: now, lastActiveAt: now, isLive: $0 == selected)
    })
    if !group.isEmpty {
      space.groups = [TabGroup(id: UUID(10), name: "Work", color: .grey)]
      for id in group {
        space.tabs[id: UUID(id)]?.groupID = UUID(10)
      }
    }
    space.selectedTabID = selected.map { UUID($0) }
    return space
  }

  private func store(_ space: Space) -> TestStoreOf<TabsFeature> {
    TestStore(initialState: space) {
      TabsFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.uuid = .incrementing
      $0.webEngine.close = { _ in }
    }
  }

  func testNewGroupGathersItsTabsWhereTheFirstIsAndTakesTheLeastUsedColor() async {
    let store = store(space(50, 51, 52, 53))
    await store.send(.newGroup(with: [UUID(51), UUID(53)])) {
      $0.groups = [TabGroup(id: UUID(0), name: "Untitled", color: .grey)]
      $0.tabs[id: UUID(51)]?.groupID = UUID(0)
      $0.tabs[id: UUID(53)]?.groupID = UUID(0)
      $0.ownTabs.move(fromOffsets: [3], toOffset: 2)
    }
    await store.receive(\.delegate.moved)
    await store.send(.newGroup(with: [UUID(50)])) {
      $0.groups.append(TabGroup(id: UUID(1), name: "Untitled", color: .blue))
      $0.tabs[id: UUID(50)]?.groupID = UUID(1)
    }
    await store.receive(\.delegate.moved)
  }

  func testTabsDragInAndOutAndAGroupWithoutTabsGoes() async {
    let store = store(space(50, 51, 52, group: [51]))
    await store.send(.group([UUID(52)], into: UUID(10))) {
      $0.tabs[id: UUID(52)]?.groupID = UUID(10)
    }
    await store.receive(\.delegate.moved)
    await store.send(.move(UUID(51), .unpinned, before: UUID(50))) {
      $0.tabs[id: UUID(51)]?.groupID = nil
      $0.ownTabs.move(fromOffsets: [1], toOffset: 0)
    }
    await store.receive(\.delegate.moved)
    await store.send(.togglePin(UUID(52))) {
      $0.tabs[id: UUID(52)]?.groupID = nil
      $0.tabs[id: UUID(52)]?.placement = .pinned
      $0.tabs[id: UUID(52)]?.pinnedURL = self.url
      $0.pinnedOrder = [UUID(52)]
      $0.groups = []
    }
    await store.receive(\.delegate.moved)
  }

  func testRemoveFromGroupPutsTheTabBelowItAndUngroupKeepsTheTabs() async {
    let store = store(space(50, 51, 52, group: [50, 51]))
    await store.send(.removeFromGroup([UUID(50)])) {
      $0.tabs[id: UUID(50)]?.groupID = nil
      $0.ownTabs.move(fromOffsets: [0], toOffset: 2)
    }
    await store.receive(\.delegate.moved)
    await store.send(.ungroup(UUID(10))) {
      $0.tabs[id: UUID(51)]?.groupID = nil
      $0.groups = []
    }
    await store.receive(\.delegate.moved)
  }

  func testRenameRecolorAndCollapseAreUndoable() async {
    let store = store(space(50, group: [50]))
    await store.send(.renameGroup(UUID(10), "  "))
    await store.send(.renameGroup(UUID(10), "Trip")) {
      $0.groups[id: UUID(10)]?.name = "Trip"
    }
    await store.receive(\.delegate.edited, .groupRenamed(UUID(10), from: "Work"))
    await store.send(.setGroupColor(UUID(10), .red)) {
      $0.groups[id: UUID(10)]?.color = .red
    }
    await store.receive(\.delegate.edited, .groupRecolored(UUID(10), from: .grey))
    await store.send(.revert(.groupRecolored(UUID(10), from: .grey))) {
      $0.groups[id: UUID(10)]?.color = .grey
    }
    await store.send(.toggleGroup(UUID(10))) {
      $0.groups[id: UUID(10)]?.isOpen = false
    }
  }

  func testCollapsedGroupsTabsLeaveTheVisibleOrderButTheShownOne() {
    var space = space(50, 51, 52, group: [50, 51], selected: 51)
    space.groups[id: UUID(10)]?.isOpen = false
    XCTAssertEqual(space.visibleOrder.map(\.id), [UUID(51), UUID(52)])
  }

  func testClosingAGroupArchivesItsTabsAndUndoBringsTheGroupBack() async {
    let initial = space(50, 51, 52, group: [51, 52], selected: 50)
    let store = store(initial)
    store.exhaustivity = .off
    await store.send(.closeGroup(UUID(10))) {
      $0.ownTabs = [initial.tabs[id: UUID(50)]!]
      $0.groups = []
    }
    let group = initial.groups[0]
    let closed = [
      ClosedTab(tab: initial.tabs[id: UUID(51)]!, index: 1, group: group),
      ClosedTab(tab: initial.tabs[id: UUID(52)]!, index: 2, group: group),
    ]
    await store.receive(\.delegate.archived, closed)
    await store.send(.restore(closed)) {
      $0.ownTabs = initial.ownTabs
      $0.groups = initial.groups
    }
  }

  func testTurningAGroupIntoAFolderPinsItsTabsAndTheGroupGoes() async {
    let store = store(space(50, 51, 52, group: [51, 52]))
    store.exhaustivity = .off
    await store.send(.newFolder("Work", in: .pinned, with: [UUID(51), UUID(52)]))
    XCTAssertEqual(store.state.folders.map(\.name), ["Work"])
    XCTAssertEqual(store.state.tabs(in: .folder(UUID(0))).map(\.id), [UUID(51), UUID(52)])
    XCTAssertEqual(store.state.tabs(in: .unpinned).map(\.id), [UUID(50)])
    XCTAssertTrue(store.state.groups.isEmpty)
  }
}
