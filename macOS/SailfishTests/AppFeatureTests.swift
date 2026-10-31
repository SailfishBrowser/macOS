import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class AppFeatureTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)
  let url = URL(string: "https://a.example")!

  func testIncognitoWindowUsesOffTheRecordContextAndIsNeverSaved() async {
    let regular = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    let calls = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        windows: [WindowFeature.State(id: UUID(300), sidebar: .init(), spaces: .init(spaces: [regular], selectedID: regular.id))],
        isLoaded: true, pendingURLs: nil
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(now)
      $0.continuousClock = ImmediateClock()
      $0.persistence.save = { _ in }
      $0.webEngine.create = { tab, profile, incognito, _, _, _ in calls.withValue { $0.append("create \(tab) \(profile) \(incognito)") } }
      $0.webEngine.load = { _, _ in }
      $0.webEngine.littleWindow = { _, _, _ in }
      $0.webEngine.close = { tab in calls.withValue { $0.append("close \(tab)") } }
      $0.webEngine.closeIncognito = { profile in calls.withValue { $0.append("closeIncognito \(profile)") } }
    }
    let incognito = Space(id: UUID(0), name: "Incognito", profileID: UUID(200), createdAt: now, isIncognito: true)
    let saved = store.state.snapshot

    await store.send(.newIncognitoWindow) {
      $0.windows.append(WindowFeature.State(id: UUID(1), sidebar: .init(), spaces: .init(spaces: [incognito], selectedID: incognito.id)))
    }
    XCTAssertEqual(store.state.snapshot, saved)
    await store.send(.windows(.element(id: UUID(1), action: .tab(.open(url), in: UUID(0))))) {
      $0.windows[id: UUID(1)]?.spaces.spaces[id: UUID(0)]?.tabs = [
        Tab(id: UUID(2), url: self.url, title: "a.example", placement: .unpinned, createdAt: self.now, lastActiveAt: self.now, isLive: true)
      ]
      $0.windows[id: UUID(1)]?.spaces.spaces[id: UUID(0)]?.selectedTabID = UUID(2)
      $0.windows[id: UUID(1)]?.spaces.spaces[id: UUID(0)]?.arrivals = [UUID(2)]
      $0.windows[id: UUID(1)]?.recentTabs = [UUID(2)]
    }
    // Links from other apps open in Little Sailfish with the last regular window's profile.
    await store.send(.openURLs([url])) {
      $0.littleSailfishes = [LittleSailfishFeature.State(id: UUID(3), profileID: UUID(200))]
    }
    await store.receive(\.littleSailfishes[id: UUID(3)].open) {
      $0.littleSailfishes[id: UUID(3)]?.commandBar = nil
      $0.littleSailfishes[id: UUID(3)]?.tab = Tab(
        id: UUID(4), url: self.url, title: "a.example", placement: .unpinned, createdAt: self.now,
        lastActiveAt: self.now, isLive: true)
    }
    await store.send(.windowClosed(UUID(1))) {
      $0.windows.remove(id: UUID(1))
    }
    await store.finish()

    XCTAssertEqual(calls.value, [
      "create \(UUID(2)) \(UUID(200)) true", "create \(UUID(4)) \(UUID(200)) false",
      "close \(UUID(2))", "closeIncognito \(UUID(200))",
    ])
  }

  private func windowStore(_ windows: IdentifiedArrayOf<WindowFeature.State>) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: AppFeature.State(windows: windows, isLoaded: true, pendingURLs: nil)) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(now)
      $0.continuousClock = ImmediateClock()
      $0.persistence.save = { _ in }
      $0.webEngine.saveSessions = {}
      $0.webEngine.keepSessions = { _ in }
      $0.webEngine.create = { _, _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
    }
    store.exhaustivity = .off
    return store
  }

  private func workWindow() -> WindowFeature.State {
    var space = Space(id: UUID(100), name: "Work", profileID: UUID(200), createdAt: now)
    space.tabs = [Tab(id: UUID(400), url: url, title: "a.example", placement: .unpinned, createdAt: now, lastActiveAt: now, isLive: true)]
    space.selectedTabID = UUID(400)
    return WindowFeature.State(id: UUID(300), sidebar: .init(), spaces: .init(spaces: [space], selectedID: space.id))
  }

  func testClosingTheLastWindowKeepsItsSpacesForTheNextOne() async {
    let store = windowStore([workWindow()])

    await store.send(.windowClosed(UUID(300)))
    XCTAssertTrue(store.state.windows.isEmpty)
    // Saved while no window is open, so quitting now keeps them too.
    XCTAssertEqual(store.state.snapshot?.windows.flatMap(\.spaces.spaces).map(\.name), ["Work"])

    await store.send(.reopen)
    XCTAssertEqual(store.state.windows.map(\.id), [UUID(300)])
    XCTAssertEqual(store.state.windows.first?.spaces.selected.selectedTabID, UUID(400))
    XCTAssertNil(store.state.closedWindow)
    XCTAssertEqual(store.state.snapshot?.windows.count, 1)
  }

  func testANewWindowBringsTheClosedSpacesBack() async {
    let store = windowStore([workWindow()])

    await store.send(.windowClosed(UUID(300)))
    await store.send(.newWindow)
    XCTAssertEqual(store.state.windows.flatMap(\.spaces.spaces).map(\.name), ["Work"])
  }

  func testAClosedWindowsProfileStaysInUse() async {
    var state = AppFeature.State(windows: [workWindow()], isLoaded: true, pendingURLs: nil)
    state.$profiles.withLock { $0 = [Profile(id: UUID(199), name: "Default"), Profile(id: UUID(200), name: "Work")] }
    let store = windowStore(state.windows)
    await store.send(.windowClosed(UUID(300)))
    state.closedWindow = store.state.closedWindow
    state.windows = []
    XCTAssertFalse(state.canDeleteProfile(UUID(200)))
  }

  func testClosingAWindowWithOthersOpenKeepsNothingBack() async {
    let other = WindowFeature.State(
      id: UUID(301), sidebar: .init(),
      spaces: .init(spaces: [Space(id: UUID(101), name: "Other", profileID: UUID(200), createdAt: now)], selectedID: UUID(101)))
    let store = windowStore([workWindow(), other])

    await store.send(.windowClosed(UUID(300)))
    XCTAssertNil(store.state.closedWindow)
    XCTAssertEqual(store.state.windows.map(\.id), [UUID(301)])
  }

  func testANewWindowsSpaceIsPrimary() async {
    let store = TestStore(initialState: AppFeature.State(isLoaded: true, pendingURLs: nil)) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(now)
      $0.continuousClock = ImmediateClock()
      $0.persistence.save = { _ in }
      $0.webEngine.saveSessions = {}
      $0.webEngine.keepSessions = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.newWindow)
    XCTAssertEqual(store.state.windows.map(\.spaces.selected.icon), [Space.primaryIcon])
  }

  func testCreateRenameAndDeleteProfilesAreSaved() async throws {
    let tab = Tab(id: UUID(400), url: url, title: "a.example", placement: .unpinned, createdAt: now, lastActiveAt: now, isLive: true)
    var space = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    space.tabs = [tab]
    space.selectedTabID = tab.id
    let other = Space(id: UUID(101), name: "Space 2", profileID: UUID(200), createdAt: now)
    let window = WindowFeature.State(id: UUID(300), sidebar: .init(), spaces: .init(spaces: [space, other], selectedID: space.id))
    let state = AppFeature.State(windows: [window], isLoaded: true, pendingURLs: nil)
    state.$profiles.withLock { $0 = [Profile(id: UUID(200), name: "Default")] }
    let saved = LockIsolated<Data?>(nil)
    let deleted = LockIsolated<[UUID]>([])
    let engine = LockIsolated<[String]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(now)
      $0.continuousClock = ImmediateClock()
      $0.persistence.save = { data in saved.setValue(data) }
      $0.webEngine.saveSessions = {}
      $0.webEngine.keepSessions = { _ in }
      $0.webEngine.deleteProfile = { id in deleted.withValue { $0.append(id) } }
      $0.webEngine.close = { id in engine.withValue { $0.append("close \(id)") } }
      $0.webEngine.create = { id, profile, _, _, _, _ in engine.withValue { $0.append("create \(id) \(profile)") } }
      $0.webEngine.load = { _, _ in }
    }

    await store.send(.createProfile(name: " Work ", spaces: [])) {
      $0.$profiles.withLock { _ = $0.append(Profile(id: UUID(0), name: "Work")) }
    }
    await store.send(.createProfile(name: " ", spaces: [UUID(100)]))
    // The space's tabs start fresh in the new profile: the selected one reloads in it.
    await store.send(.createProfile(name: "Home", spaces: [UUID(100)])) {
      $0.$profiles.withLock { _ = $0.append(Profile(id: UUID(1), name: "Home")) }
      $0.windows[id: UUID(300)]?.spaces.spaces[id: UUID(100)]?.profileID = UUID(1)
      $0.windows[id: UUID(300)]?.spaces.spaces[id: UUID(100)]?.tabs[id: UUID(400)]?.isLive = false
    }
    await store.receive(\.windows[id: UUID(300)].spaces.spaces[id: UUID(100)].activate) {
      $0.windows[id: UUID(300)]?.spaces.spaces[id: UUID(100)]?.tabs[id: UUID(400)]?.isLive = true
    }
    await store.send(.renameProfile(UUID(0), name: " Personal ")) {
      $0.$profiles.withLock { $0[id: UUID(0)]?.name = "Personal" }
    }
    await store.send(.renameProfile(UUID(0), name: " "))
    await store.send(.deleteProfile(UUID(1)))
    await store.send(.deleteProfile(UUID(0))) {
      $0.$profiles.withLock { _ = $0.remove(id: UUID(0)) }
    }
    await store.send(.deleteProfile(UUID(0)))
    await store.finish()
    XCTAssertEqual(deleted.value, [UUID(0)])
    XCTAssertEqual(engine.value, ["close \(UUID(400))", "create \(UUID(400)) \(UUID(1))"])

    let snapshot = try Snapshot.decode(XCTUnwrap(saved.value))
    XCTAssertEqual(snapshot.profiles, [Profile(id: UUID(200), name: "Default"), Profile(id: UUID(1), name: "Home")])
    XCTAssertEqual(snapshot.windows[0].spaces.spaces.map(\.profileID), [UUID(1), UUID(200)])
  }

  func testUnusedProfilesAreDeletedTogetherAndDefaultIsKept() async {
    let space = Space(id: UUID(1), name: "Work", profileID: UUID(201), createdAt: now)
    let window = WindowFeature.State(id: UUID(2), sidebar: .init(), spaces: .init(spaces: [space], selectedID: space.id))
    let state = AppFeature.State(windows: [window])
    state.$profiles.withLock {
      $0 = [
        Profile(id: UUID(200), name: "Default"), Profile(id: UUID(201), name: "Work"),
        Profile(id: UUID(202), name: "Old"), Profile(id: UUID(203), name: "Older"),
      ]
    }
    let deleted = LockIsolated<[UUID]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.webEngine.deleteProfile = { id in deleted.withValue { $0.append(id) } }
    }
    XCTAssertEqual(store.state.unusedProfiles.map(\.name), ["Old", "Older"])
    XCTAssertFalse(store.state.canDeleteProfile(UUID(200)))

    await store.send(.deleteUnusedProfiles) {
      $0.$profiles.withLock { $0 = [Profile(id: UUID(200), name: "Default"), Profile(id: UUID(201), name: "Work")] }
    }
    await store.send(.deleteUnusedProfiles)
    await store.finish()
    XCTAssertEqual(deleted.value, [UUID(202), UUID(203)])
  }

  func testSpacesOfAMissingProfileRevertToDefaultOnLoad() async {
    let kept = Space(id: UUID(1), name: "Home", profileID: UUID(200), createdAt: now)
    let lost = Space(id: UUID(2), name: "Work", profileID: UUID(999), createdAt: now)
    let snapshot = Snapshot(
      profiles: [Profile(id: UUID(200), name: "Default")],
      windows: [Snapshot.Window(id: UUID(3), frame: nil, sidebar: .init(), spaces: .init(spaces: [kept, lost], selectedID: kept.id))])
    let store = TestStore(initialState: AppFeature.State(pendingURLs: nil)) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(now)
      $0.continuousClock = ImmediateClock()
      $0.persistence.save = { _ in }
      $0.webEngine.saveSessions = {}
      $0.webEngine.keepSessions = { _ in }
    }

    await store.send(.loaded(.success(snapshot))) {
      $0.$profiles.withLock { $0 = [Profile(id: UUID(200), name: "Default")] }
      var reverted = lost
      reverted.profileID = UUID(200)
      $0.windows = [WindowFeature.State(id: UUID(3), sidebar: .init(), spaces: .init(spaces: [kept, reverted], selectedID: kept.id))]
      $0.recoveredSpaces = ["Work"]
      $0.isLoaded = true
      $0.$firstLaunch.withLock { $0 = self.now }
      $0.$mediaFoldersAsked.withLock { $0 = true }
    }
    await store.receive(\.windows[id: UUID(3)].spaces.spaces[id: UUID(1)].activate)
    await store.send(.dismissRecoveredSpaces) {
      $0.recoveredSpaces = []
    }
    await store.finish()
  }

  func testAProfileOfAnOpenLittleSailfishIsNeverDeleted() async {
    let state = AppFeature.State(littleSailfishes: [LittleSailfishFeature.State(id: UUID(1), profileID: UUID(201))])
    state.$profiles.withLock { $0 = [Profile(id: UUID(200), name: "Default"), Profile(id: UUID(201), name: "Work")] }
    let store = TestStore(initialState: state) {
      AppFeature()
    }
    XCTAssertFalse(store.state.canDeleteProfile(UUID(201)))
    await store.send(.deleteProfile(UUID(201)))
    await store.send(.deleteUnusedProfiles)
  }

  func testTheLastProfileAndProfilesOfIncognitoWindowsAreNeverDeleted() async {
    let incognito = Space(id: UUID(1), name: "Incognito", profileID: UUID(201), createdAt: now, isIncognito: true)
    let window = WindowFeature.State(id: UUID(2), sidebar: .init(), spaces: .init(spaces: [incognito], selectedID: incognito.id))
    let state = AppFeature.State(windows: [window])
    state.$profiles.withLock { $0 = [Profile(id: UUID(200), name: "Default"), Profile(id: UUID(201), name: "Work")] }
    let store = TestStore(initialState: state) {
      AppFeature()
    }

    await store.send(.deleteProfile(UUID(201)))

    let last = AppFeature.State()
    last.$profiles.withLock { $0 = [Profile(id: UUID(200), name: "Default")] }
    let lastStore = TestStore(initialState: last) {
      AppFeature()
    }
    await lastStore.send(.deleteProfile(UUID(200)))
  }
}
