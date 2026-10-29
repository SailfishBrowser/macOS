import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class TabsFeatureTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)
  let a = URL(string: "https://a.example")!
  let b = URL(string: "https://b.example")!

  func testIdleTodayTabsArchiveAfterTheProfilesInterval() async {
    @Shared(.profiles) var profiles = [Profile(id: UUID(200), name: "Default")]
    var space = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    let old = now.addingTimeInterval(-12 * 3600)
    space.tabs = [
      Tab(id: UUID(50), url: a, title: "A", placement: .unpinned, createdAt: old, lastActiveAt: old),
      Tab(id: UUID(51), url: b, title: "B", placement: .unpinned, createdAt: old, lastActiveAt: now),
      Tab(id: UUID(52), url: a, title: "A", placement: .pinned, pinnedURL: a, createdAt: old, lastActiveAt: old),
    ]
    let store = TestStore(initialState: space) {
      TabsFeature()
    } withDependencies: {
      $0.date = .constant(now)
    }

    await store.send(.archiveIdle) {
      $0.tabs.remove(id: UUID(50))
    }
    await store.receive(\.delegate.autoArchived, 1)
    @Shared(.archive) var archive
    XCTAssertEqual(archive.map(\.id), [UUID(50)])
  }

  func testDeletingAFolderArchivesWhatIsInItAndUndoPutsItBack() async {
    var space = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    space.folders = [Folder(id: UUID(10), name: "Work"), Folder(id: UUID(11), name: "Docs", placement: .folder(UUID(10)))]
    space.tabs = [
      Tab(id: UUID(50), url: a, title: "A", placement: .pinned, pinnedURL: a, createdAt: now, lastActiveAt: now),
      Tab(id: UUID(51), url: b, title: "B", placement: .folder(UUID(10)), pinnedURL: b, createdAt: now, lastActiveAt: now, isLive: true),
      Tab(id: UUID(52), url: a, title: "C", placement: .folder(UUID(11)), pinnedURL: a, createdAt: now, lastActiveAt: now),
    ]
    space.pinnedOrder = [UUID(50), UUID(10), UUID(51), UUID(11), UUID(52)]
    let closed = LockIsolated<[UUID]>([])
    let store = TestStore(initialState: space) {
      TabsFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.webEngine.create = { _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
      $0.webEngine.close = { tab in closed.withValue { $0.append(tab) } }
    }
    store.exhaustivity = .off
    var tabB = space.tabs[id: UUID(51)]!
    tabB.isLive = false
    let removal = FolderRemoval(
      folders: Array(space.folders),
      closed: [ClosedTab(tab: tabB, index: 1), ClosedTab(tab: space.tabs[id: UUID(52)]!, index: 2)],
      pinnedOrder: space.pinnedOrder)

    await store.send(.deleteFolder(UUID(10)))
    await store.receive(\.delegate.folderDeleted, removal)
    XCTAssertEqual(store.state.folders, [])
    XCTAssertEqual(store.state.tabs.map(\.id), [UUID(50)])
    XCTAssertEqual(closed.value, [UUID(51)])
    @Shared(.archive) var archive
    XCTAssertEqual(archive.map(\.id), [UUID(52), UUID(51)])

    await store.send(.restoreFolder(removal))
    XCTAssertEqual(store.state.tree().map(\.id), [UUID(50), UUID(10), UUID(51), UUID(11), UUID(52)])
    XCTAssertEqual(archive, [])
    XCTAssertEqual(store.state.selectedTabID, UUID(52))
  }

  func testAPinnedTabOffItsSiteShowsItsPinnedPagesIconAndClosedKeepsNoneOfThatSite() async {
    let pinned = URL(string: "https://mail.example/inbox")!
    let icon = NSImage(size: NSSize(width: 16, height: 16))
    var tab = Tab(
      id: UUID(50), url: pinned, title: "Mail", placement: .pinned, pinnedURL: pinned, createdAt: now,
      lastActiveAt: now, favicon: icon, isLive: true)
    XCTAssertEqual(tab.iconPage, pinned)
    XCTAssertIdentical(tab.pageFavicon, icon)
    tab.url = URL(string: "https://mail.example/thread")!
    XCTAssertEqual(tab.iconPage, tab.url)
    XCTAssertIdentical(tab.pageFavicon, icon)
    tab.url = URL(string: "https://accounts.example/signin")!
    XCTAssertEqual(tab.iconPage, pinned)
    XCTAssertNil(tab.pageFavicon)

    var space = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    space.tabs = [tab]
    space.selectedTabID = tab.id
    let store = TestStore(initialState: space) {
      TabsFeature()
    } withDependencies: {
      $0.webEngine.discard = { _ in }
    }
    await store.send(.close(UUID(50))) {
      $0.tabs[id: UUID(50)] = Tab(
        id: UUID(50), url: pinned, title: "Mail", placement: .pinned, pinnedURL: pinned, createdAt: self.now,
        lastActiveAt: self.now)
      $0.selectedTabID = nil
    }
  }

  func testSplitResizeMoveAndClosePanes() async {
    let c = URL(string: "https://c.example")!
    var space = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    space.tabs = [
      Tab(id: UUID(50), url: a, title: "A", placement: .pinned, pinnedURL: a, createdAt: now, lastActiveAt: now, isLive: true),
      Tab(id: UUID(51), url: b, title: "B", placement: .unpinned, createdAt: now, lastActiveAt: now, isLive: true),
    ]
    space.selectedTabID = UUID(50)
    let store = TestStore(initialState: space) {
      TabsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(now)
      $0.webEngine.create = { _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
      $0.webEngine.close = { _ in }
    }

    await store.send(.split(UUID(51), beside: UUID(50))) {
      $0.tabs[id: UUID(51)]?.placement = .pinned
      $0.tabs[id: UUID(51)]?.pinnedURL = self.b
      $0.splits = [Split(id: UUID(0), tabIDs: [UUID(50), UUID(51)], widths: [0.5, 0.5])]
      $0.selectedTabID = UUID(51)
    }
    await store.send(.openInSplit(c, beside: UUID(51))) {
      $0.tabs.append(
        Tab(id: UUID(1), url: c, title: "c.example", placement: .pinned, pinnedURL: c, createdAt: self.now, lastActiveAt: self.now, isLive: true))
      $0.splits[id: UUID(0)]?.tabIDs.append(UUID(1))
      $0.splits[id: UUID(0)]?.widths = [1.0 / 3, 1.0 / 3, 1.0 / 3]
      $0.selectedTabID = UUID(1)
    }
    await store.send(.resizeSplit(UUID(0), divider: 0, position: 0.5)) {
      $0.splits[id: UUID(0)]?.widths = [0.5, (1.0 / 3 + 1.0 / 3) - 0.5, 1.0 / 3]
    }
    await store.send(.move(UUID(51), .unpinned, before: nil)) {
      for id in [UUID(50), UUID(51), UUID(1)] {
        $0.tabs[id: id]?.placement = .unpinned
        $0.tabs[id: id]?.pinnedURL = nil
      }
    }
    await store.receive(\.delegate.moved)
    await store.send(.close(UUID(1))) {
      $0.tabs.remove(id: UUID(1))
      $0.splits[id: UUID(0)]?.tabIDs = [UUID(50), UUID(51)]
      $0.splits[id: UUID(0)]?.widths = [0.5 / (1 - 1.0 / 3), ((1.0 / 3 + 1.0 / 3) - 0.5) / (1 - 1.0 / 3)]
      $0.selectedTabID = UUID(51)
    }
    await store.receive(\.delegate.archived)
    await store.send(.close(UUID(50))) {
      $0.tabs.remove(id: UUID(50))
      $0.splits = []
    }
    await store.receive(\.delegate.archived)
    await store.finish()
    @Shared(.archive) var archive
    XCTAssertEqual(archive.map(\.id), [UUID(50), UUID(1)])
  }

  func testPaneShortcutsMoveAndSeparatePanes() async {
    var space = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    space.tabs = IdentifiedArray(uniqueElements: (50...52).map {
      Tab(id: UUID($0), url: a, title: "A", placement: .unpinned, createdAt: now, lastActiveAt: now, isLive: true)
    })
    space.splits = [Split(id: UUID(0), tabIDs: [UUID(50), UUID(51), UUID(52)], widths: [0.5, 0.3, 0.2])]
    space.selectedTabID = UUID(50)
    let store = TestStore(initialState: space) {
      TabsFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.webEngine.create = { _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.selectPane(2)) { $0.selectedTabID = UUID(52) }
    await store.send(.selectPane(3))
    XCTAssertEqual(store.state.selectedTabID, UUID(52))
    // Stepping past the last pane wraps to the first, and back.
    await store.send(.cyclePane(1)) { $0.selectedTabID = UUID(50) }
    await store.send(.cyclePane(-1)) { $0.selectedTabID = UUID(52) }

    await store.send(.movePane(UUID(50), by: 1)) {
      $0.splits[id: UUID(0)]?.tabIDs = [UUID(51), UUID(50), UUID(52)]
      $0.splits[id: UUID(0)]?.widths = [0.3, 0.5, 0.2]
    }
    await store.send(.movePane(UUID(51), by: -1))
    XCTAssertEqual(store.state.splits[id: UUID(0)]?.tabIDs, [UUID(51), UUID(50), UUID(52)])

    // A separated pane stays a tab; the rest of the split shares its width.
    await store.send(.separate(UUID(52))) {
      $0.splits[id: UUID(0)]?.tabIDs = [UUID(51), UUID(50)]
      $0.splits[id: UUID(0)]?.widths = [0.3 / (1 - 0.2), 0.5 / (1 - 0.2)]
    }
    XCTAssertEqual(store.state.tabs.ids, [UUID(50), UUID(51), UUID(52)])
    await store.send(.toggleVerticalSplit(UUID(0))) { $0.splits[id: UUID(0)]?.isVertical = true }
    await store.send(.separateAll(UUID(0))) { $0.splits = [] }
    XCTAssertEqual(store.state.tabs.count, 3)
  }

  func testSplitSavedWithoutOrientationLoadsHorizontal() throws {
    let json = #"{"id":"00000000-0000-0000-0000-000000000000","tabIDs":[],"widths":[]}"#
    let split = try JSONDecoder().decode(Split.self, from: Data(json.utf8))
    XCTAssertFalse(split.isVertical)
  }
}
