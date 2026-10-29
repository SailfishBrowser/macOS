import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class OnboardingTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)

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
      $0.webEngine.create = { _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
      $0.webEngine.littleWindow = { _, _, _ in }
      $0.browserImport.isDefaultBrowser = { false }
    }
    store.exhaustivity = .off
    return store
  }

  func testAFirstLaunchShowsArcsOnboardingUntilItsLastStep() async {
    let store = appStore(load: nil)
    await store.send(.launched)
    await store.receive(\.loaded.success)
    XCTAssertEqual(store.state.onboarding, .pending)
    XCTAssertEqual(store.state.windows.map(\.importer?.step), [.browsers])
    XCTAssertEqual(store.state.windows[0].importer?.isOnboarding, true)
    XCTAssertEqual(store.state.windows[0].importer?.spaceName, "Space 1")

    let window = store.state.windows[0].id
    var steps: [ImportFeature.Step] = []
    for _ in 0..<5 {
      await store.send(.windows(.element(id: window, action: .importer(.presented(.nextTapped)))))
      steps.append(store.state.windows[0].importer!.step)
    }
    XCTAssertEqual(steps, [.defaultBrowser, .theme, .adBlocker, .mediaFolders, .welcome])
    XCTAssertEqual(store.state.onboarding, .pending)
    await store.send(.windows(.element(id: window, action: .importer(.presented(.doneTapped)))))
    await store.skipReceivedActions()
    XCTAssertEqual(store.state.onboarding, .done)
    XCTAssertNil(store.state.windows[0].importer)
  }

  func testAFirstLaunchThatOpensALinkLeavesTheWelcomeForTheNextLaunch() async {
    let store = appStore(load: nil)
    await store.send(.openURLs([URL(string: "https://a.example/")!]))
    await store.send(.launched)
    await store.receive(\.loaded.success)
    XCTAssertEqual(store.state.onboarding, .pending)
    XCTAssertNil(store.state.windows[0].importer)
    XCTAssertEqual(store.state.littleSailfishes.count, 1)
  }

  func testALaunchWithSavedStateNeverShowsIt() async throws {
    let space = Space(id: UUID(100), name: "Home", profileID: UUID(200), createdAt: now)
    let snapshot = Snapshot(
      profiles: [Profile(id: UUID(200), name: "Default")], archive: [],
      windows: [Snapshot.Window(id: UUID(300), frame: nil, sidebar: .init(), spaces: .init(spaces: [space], selectedID: space.id))],
      focusedWindow: nil)
    let store = appStore(load: try snapshot.encoded())
    await store.send(.launched)
    await store.receive(\.loaded.success)
    XCTAssertEqual(store.state.onboarding, .undecided)
    XCTAssertNil(store.state.windows[0].importer)
  }

  func testAnInstallPastOnboardingIsAskedForMediasFoldersOnceAtItsNextLaunch() async throws {
    let space = Space(id: UUID(100), name: "Home", profileID: UUID(200), createdAt: now)
    let snapshot = try Snapshot(
      profiles: [Profile(id: UUID(200), name: "Default")], archive: [],
      windows: [Snapshot.Window(id: UUID(300), frame: nil, sidebar: .init(), spaces: .init(spaces: [space], selectedID: space.id))],
      focusedWindow: nil
    ).encoded()
    let requests = LockIsolated(0)
    for _ in 0..<2 {
      let store = appStore(load: snapshot)
      store.dependencies.requestMediaFolders = { requests.withValue { $0 += 1 } }
      await store.send(.launched)
      await store.receive(\.loaded.success)
      await store.skipInFlightEffects()
      XCTAssertTrue(store.state.mediaFoldersAsked)
    }
    XCTAssertEqual(requests.value, 1)
  }

  func testAFirstLaunchLeavesMediasFoldersToTheOnboarding() async {
    let store = appStore(load: nil)
    store.dependencies.requestMediaFolders = { XCTFail("asked at launch") }
    await store.send(.launched)
    await store.receive(\.loaded.success)
    XCTAssertFalse(store.state.mediaFoldersAsked)
  }

  private func windowStore() -> TestStoreOf<WindowFeature> {
    let home = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now, icon: Space.primaryIcon)
    var state = WindowFeature.State(id: UUID(300), sidebar: .init(), spaces: .init(spaces: [home], selectedID: home.id))
    state.spaces.$profiles.withLock { $0 = [Profile(id: UUID(200), name: "Default")] }
    state.importer = .onboarding(spaceName: "Space 1")
    state.importer?.$onboarding.withLock { $0 = .pending }
    let store = TestStore(initialState: state) {
      WindowFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(now)
      $0.continuousClock = ImmediateClock()
      $0.browserImport.bookmarks = { _, _ in
        [.tab(ArcData.Tab(url: URL(string: "https://a.example/")!, title: "A", createdAt: Date(timeIntervalSince1970: 0)))]
      }
      $0.webEngine.create = { _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
      $0.browserImport.isDefaultBrowser = { false }
    }
    store.exhaustivity = .off
    return store
  }

  func testTheThemeStepThemesTheShownSpace() async {
    let store = windowStore()
    await store.send(.importer(.presented(.nextTapped)))
    await store.send(.importer(.presented(.nextTapped)))
    XCTAssertEqual(store.state.importer?.step, .theme)
    let theme = SpaceTheme(colors: [0xFF0000])
    await store.send(.importer(.presented(.themeChosen(theme))))
    await store.skipReceivedActions()
    XCTAssertEqual(store.state.spaces.selected.theme, theme)
    XCTAssertEqual(store.state.spaces.selected.name, "Space 1")
    XCTAssertEqual(store.state.importer?.step, .adBlocker)
  }

  func testTheMediaFoldersStepRaisesTheirPromptsOnceThenWelcomes() async {
    let requests = LockIsolated(0)
    let store = windowStore()
    store.dependencies.requestMediaFolders = { requests.withValue { $0 += 1 } }
    for _ in 0..<4 {
      await store.send(.importer(.presented(.nextTapped)))
    }
    XCTAssertEqual(store.state.importer?.step, .mediaFolders)
    @Shared(.mediaFoldersAsked) var asked
    XCTAssertFalse(asked)
    await store.send(.importer(.presented(.mediaFoldersTapped)))
    await store.receive(\.importer.presented.nextTapped)
    await store.send(.importer(.presented(.mediaFoldersTapped)))
    XCTAssertTrue(asked)
    XCTAssertEqual(requests.value, 1)
    XCTAssertEqual(store.state.importer?.step, .welcome)
  }

  func testAnOnboardingGoneThroughAgainLeavesOutTheMediaFoldersStepOnceAsked() async {
    let store = windowStore()
    @Shared(.mediaFoldersAsked) var asked
    $asked.withLock { $0 = true }
    for _ in 0..<4 {
      await store.send(.importer(.presented(.nextTapped)))
    }
    XCTAssertEqual(store.state.importer?.step, .welcome)
  }

  func testTheThemeStepNamesTheFirstSpaceOrKeepsItsNameWhenLeftEmpty() async {
    for (typed, name) in [("  Home ", "Home"), ("   ", "Space 1")] {
      let store = windowStore()
      await store.send(.importer(.presented(.nextTapped)))
      await store.send(.importer(.presented(.nextTapped)))
      await store.send(.importer(.presented(.binding(.set(\.spaceName, typed)))))
      await store.send(.importer(.presented(.themeChosen(SpaceTheme()))))
      await store.skipReceivedActions()
      XCTAssertEqual(store.state.spaces.selected.name, name)
    }
  }

  func testAnOnboardingImportGivesTheFirstSpaceTheSailAndLeavesTheOthersTheirIcons() async {
    let store = windowStore()
    let data = ArcData(spaces: [
      ArcData.Space(name: "Work", icon: "🐟", profile: nil, pinned: [], today: []),
      ArcData.Space(name: "Home", icon: "🏠", profile: nil, pinned: [], today: []),
      ArcData.Space(name: "Play", icon: "", profile: nil, pinned: [], today: []),
    ])
    await store.send(.importer(.presented(.delegate(.merge(data, ArcShortcuts(), [.spaces], from: .arc)))))
    XCTAssertEqual(store.state.spaces.spaces.map(\.name), ["Work", "Home", "Play"])
    XCTAssertEqual(store.state.spaces.spaces.map(\.icon), [Space.primaryIcon, "🏠", ""])
  }

  func testALaterImportLeavesTheFirstSpacesIconAndAddsTheImportedOnesWithTheirOwn() async {
    let store = windowStore()
    await store.send(.importer(.dismiss))
    await store.send(.showImport)
    let data = ArcData(spaces: [ArcData.Space(name: "Work", icon: "🐟", profile: nil, pinned: [], today: [])])
    await store.send(.importer(.presented(.delegate(.merge(data, ArcShortcuts(), [.spaces], from: .arc)))))
    XCTAssertEqual(store.state.spaces.spaces.map(\.icon), [Space.primaryIcon, "🐟"])
  }

  func testTheDefaultBrowserStepSetsItOrIsLeftOutWhenItAlreadyIs() async {
    let made = LockIsolated(false)
    let store = TestStore(initialState: ImportFeature.State.onboarding(spaceName: "Space 1")) {
      ImportFeature()
    } withDependencies: {
      $0.browserImport.isDefaultBrowser = { false }
      $0.browserImport.makeDefaultBrowser = { made.setValue(true) }
    }
    await store.send(.nextTapped) { $0.step = .defaultBrowser }
    await store.send(.makeDefaultTapped)
    await store.receive(\.nextTapped) { $0.step = .theme }
    XCTAssertTrue(made.value)

    let isDefault = TestStore(initialState: ImportFeature.State.onboarding(spaceName: "Space 1")) {
      ImportFeature()
    } withDependencies: {
      $0.browserImport.isDefaultBrowser = { true }
    }
    await isDefault.send(.nextTapped) { $0.step = .theme }
  }

  func testAnImportReplacesTheEmptyFirstSpace() async {
    let store = windowStore()
    let chrome = BrowserSource(browser: .chrome, profiles: [BrowserProfile(name: "Me", folder: URL(filePath: "/chrome/Default"))])
    await store.send(.importer(.presented(.sourcesLoaded([chrome]))))
    await store.send(.importer(.presented(.browserTapped(.chrome))))
    await store.receive(\.importer.presented.bookmarksLoaded)
    var options = store.state.importer!.options!
    options.includesHistory = false
    options.includesPasswords = false
    options.includesCookies = false
    options.spaceName = "Bookmarks"
    await store.send(.importer(.presented(.binding(.set(\.options, options)))))
    await store.send(.importer(.presented(.importTapped)))
    await store.receive(\.importer.presented.finished)
    await store.skipReceivedActions()
    XCTAssertEqual(store.state.spaces.spaces.map(\.name), ["Bookmarks"])
    XCTAssertEqual(store.state.spaces.selected.tabs.count, 1)
    XCTAssertNil(store.state.importer?.spaceName)

    await store.send(.importer(.presented(.doneTapped)))
    XCTAssertEqual(store.state.importer?.step, .defaultBrowser)
  }

  func testBackFromABrowsersOptionsReturnsToTheBrowserList() async {
    var state = ImportFeature.State.onboarding(spaceName: "Space 1")
    state.step = .options
    let store = TestStore(initialState: state) { ImportFeature() }
    await store.send(.backTapped) { $0.step = .browsers }
  }
}
