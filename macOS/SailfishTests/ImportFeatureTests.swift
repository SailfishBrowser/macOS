import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class ImportFeatureTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)
  let chrome = BrowserSource(browser: .chrome, profiles: [
    BrowserProfile(name: "Me", folder: URL(filePath: "/chrome/Default")),
    BrowserProfile(name: "Work", folder: URL(filePath: "/chrome/Profile 1")),
  ])

  private func tab(_ url: String) -> ArcData.Tab {
    ArcData.Tab(url: URL(string: url)!, title: url, createdAt: Date(timeIntervalSince1970: 0))
  }

  func testChromeBookmarksBecomeANamedSpaceAndItsHistoryGoesToTheFirstProfile() async {
    let home = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    let rows: [ArcData.Row] = [.tab(tab("https://a.example/")), .folder(name: "Work", rows: [.tab(tab("https://b.example/"))])]
    let imported = LockIsolated<[String]>([])
    @Shared(.profiles) var profiles
    $profiles.withLock { $0 = [Profile(id: UUID(200), name: "Default")] }
    let store = TestStore(
      initialState: WindowFeature.State(id: UUID(300), sidebar: .init(), spaces: .init(spaces: [home], selectedID: home.id))
    ) {
      WindowFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(now)
      $0.continuousClock = ImmediateClock()
      $0.browserImport.sources = { [self.chrome] }
      $0.browserImport.bookmarks = { _, profile in profile.name == "Work" ? rows : [] }
      $0.browserImport.history = { browser, profile, into in
        imported.withValue { $0.append("\(browser.rawValue) \(profile.name) \(into)") }
        return 7
      }
      $0.browserImport.safeStorageKey = { _ in Data("key".utf8) }
      $0.browserImport.passwords = { _, _, _, _ in 3 }
      $0.browserImport.cookies = { _, _, _, _ in 5 }
      $0.webEngine.create = { _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.showImport)
    await store.send(.importer(.presented(.appeared)))
    await store.receive(\.importer.presented.sourcesLoaded)
    await store.send(.importer(.presented(.browserTapped(.chrome))))
    await store.receive(\.importer.presented.bookmarksLoaded)
    await store.send(.importer(.presented(.profileChosen(chrome.profiles[1]))))
    await store.receive(\.importer.presented.bookmarksLoaded)
    XCTAssertEqual(store.state.importer?.options?.bookmarks, rows)
    XCTAssertEqual(store.state.importer?.options?.spaceName, "Google Chrome")
    var options = store.state.importer!.options!
    options.spaceName = " Work "
    await store.send(.importer(.presented(.binding(.set(\.options, options)))))
    await store.send(.importer(.presented(.importTapped)))
    await store.receive(\.importer.presented.delegate.merge)
    await store.receive(\.importer.presented.finished)
    await store.skipReceivedActions()

    XCTAssertEqual(store.state.importer?.summary, ImportFeature.Summary(browser: .chrome, spaces: 1, tabs: 2, pages: 7, passwords: 3, cookies: 5))
    XCTAssertEqual(store.state.spaces.spaces.map(\.name), ["Space 1", "Work"])
    let space = store.state.spaces.spaces[1]
    XCTAssertEqual(space.profileID, UUID(200))
    XCTAssertEqual(space.folders.map(\.name), ["Work"])
    XCTAssertEqual(space.tabs.map(\.url.absoluteString).sorted(), ["https://a.example/", "https://b.example/"])
    XCTAssertEqual(imported.value, ["Google Chrome Work \(UUID(200))"])
    XCTAssertEqual(store.state.undoStack.last?.name, "Import from Google Chrome")
  }

  func testSafariWithoutFullDiskAccessSaysHowToGrantItAndImportsNothing() async {
    let safari = BrowserSource(browser: .safari, profiles: [BrowserProfile(name: "", folder: URL(filePath: "/Safari"))])
    var state = ImportFeature.State()
    state.sources = [safari]
    let store = TestStore(initialState: state) {
      ImportFeature()
    } withDependencies: {
      $0.browserImport.bookmarks = { _, _ in throw ImportError.needsFullDiskAccess }
    }

    await store.send(.browserTapped(.safari)) {
      $0.step = .options
      $0.options = ImportFeature.Options(browser: .safari, profiles: safari.profiles, profile: safari.profiles[0], spaceName: "Safari")
    }
    await store.receive(\.bookmarksLoaded) { $0.options?.failure = .needsFullDiskAccess }
    XCTAssertFalse(store.state.options!.canImport)
    await store.send(.importTapped)
  }

  func testArcHistoryGoesOnlyToTheProfilesItsImportMade() async {
    let profiles = [
      BrowserProfile(name: "Personal", folder: URL(filePath: "/Arc/User Data/Default")),
      BrowserProfile(name: "Work", folder: URL(filePath: "/Arc/User Data/Profile 1")),
      BrowserProfile(name: "Old", folder: URL(filePath: "/Arc/User Data/Profile 2")),
    ]
    @Shared(.profiles) var shared
    $shared.withLock { $0 = [Profile(id: UUID(200), name: "Default"), Profile(id: UUID(201), name: "Work")] }
    let imported = LockIsolated<[String]>([])
    let data = ArcData(spaces: [ArcData.Space(name: "Home", icon: "", pinned: [.tab(tab("https://a.example/"))], today: [])])
    let store = TestStore(initialState: ImportFeature.State.arc(folder: URL(filePath: "/Arc"))) {
      ImportFeature()
    } withDependencies: {
      $0.browserImport.arcProfiles = { _ in profiles }
      $0.browserImport.history = { _, profile, into in
        imported.withValue { $0.append("\(profile.name) \(into)") }
        return 1
      }
    }
    store.exhaustivity = .off

    await store.send(.arc(.delegate(.import(data, ArcShortcuts(), [.spaces, .pinnedTabs, .history]))))
    await store.receive(\.delegate.merge)
    await store.receive(\.finished) {
      $0.summary = ImportFeature.Summary(browser: .arc, spaces: 1, tabs: 1, pages: 2)
    }
    XCTAssertEqual(imported.value, ["Personal \(UUID(200))", "Work \(UUID(201))"])
  }

  func testArcFaviconsOfAllItsPagesAreKeptBeforeTheTabsShow() async {
    let profiles = [BrowserProfile(name: "Personal", folder: URL(filePath: "/Arc/User Data/Default"))]
    let kept = LockIsolated<[URL]>([])
    let data = ArcData(
      spaces: [ArcData.Space(
        name: "Home", icon: "", pinned: [.folder(name: "Work", rows: [.tab(tab("https://a.example/"))])],
        today: [tab("https://b.example/")])],
      favorites: [ArcData.Favorites(tabs: [tab("https://c.example/")])],
      archive: [ArcData.Archived(url: URL(string: "https://d.example/")!, title: "", archivedAt: now)])
    let store = TestStore(initialState: ImportFeature.State.arc(folder: URL(filePath: "/Arc"))) {
      ImportFeature()
    } withDependencies: {
      $0.browserImport.arcProfiles = { _ in profiles }
      $0.browserImport.favicons = { received, pages in
        XCTAssertEqual(received, profiles)
        kept.setValue(pages)
      }
    }
    store.exhaustivity = .off

    await store.send(.arc(.delegate(.import(data, ArcShortcuts(), [.spaces, .pinnedTabs]))))
    XCTAssertEqual(kept.value.map(\.host), ["a.example", "b.example", "c.example", "d.example"])
    await store.receive(\.delegate.merge)
    await store.receive(\.finished)
  }

  func testChromiumPasswordsAndCookiesAreDecryptedWithTheKeyAskedForOnceAndGoToTheChosenProfile() async {
    @Shared(.profiles) var shared
    $shared.withLock { $0 = [Profile(id: UUID(200), name: "Default")] }
    let calls = LockIsolated<[String]>([])
    var state = ImportFeature.State()
    state.sources = [chrome]
    let store = TestStore(initialState: state) {
      ImportFeature()
    } withDependencies: {
      $0.browserImport.bookmarks = { _, _ in [] }
      $0.browserImport.safeStorageKey = { browser in
        calls.withValue { $0.append("key \(browser.rawValue)") }
        return Data("key".utf8)
      }
      $0.browserImport.passwords = { browser, profile, key, into in
        calls.withValue { $0.append("passwords \(browser.rawValue) \(profile.name) \(key == Data("key".utf8)) \(into)") }
        return 2
      }
      $0.browserImport.cookies = { _, profile, key, into in
        calls.withValue { $0.append("cookies \(profile.name) \(key == Data("key".utf8)) \(into)") }
        return 4
      }
    }
    store.exhaustivity = .off

    await store.send(.browserTapped(.chrome))
    await store.send(.profileChosen(chrome.profiles[1]))
    await store.receive(\.bookmarksLoaded)
    XCTAssertTrue(store.state.options!.includesPasswords && store.state.options!.includesCookies)
    var options = store.state.options!
    options.includesBookmarks = false
    options.includesHistory = false
    await store.send(.binding(.set(\.options, options)))
    await store.send(.importTapped)
    await store.receive(\.finished) {
      $0.summary = ImportFeature.Summary(browser: .chrome, passwords: 2, cookies: 4)
    }
    XCTAssertEqual(calls.value, [
      "key Google Chrome", "passwords Google Chrome Work true \(UUID(200))", "cookies Work true \(UUID(200))",
    ])
  }

  func testADeniedKeychainPromptImportsNoPasswordsOrCookiesButStillTheHistory() async {
    @Shared(.profiles) var shared
    $shared.withLock { $0 = [Profile(id: UUID(200), name: "Default")] }
    var state = ImportFeature.State()
    state.sources = [chrome]
    let store = TestStore(initialState: state) {
      ImportFeature()
    } withDependencies: {
      $0.browserImport.bookmarks = { _, _ in [] }
      $0.browserImport.safeStorageKey = { _ in throw ImportError.keychainDenied }
      $0.browserImport.history = { _, _, _ in 9 }
    }
    store.exhaustivity = .off

    await store.send(.browserTapped(.chrome))
    await store.receive(\.bookmarksLoaded)
    var options = store.state.options!
    options.includesBookmarks = false
    await store.send(.binding(.set(\.options, options)))
    await store.send(.importTapped)
    await store.receive(\.finished) {
      $0.summary = ImportFeature.Summary(browser: .chrome, pages: 9, passwords: 0, cookies: 0, failure: .keychainDenied)
    }
  }

  func testArcPasswordsAndCookiesGoOnlyToTheProfilesItsImportMade() async {
    let profiles = [
      BrowserProfile(name: "Personal", folder: URL(filePath: "/Arc/User Data/Default")),
      BrowserProfile(name: "Old", folder: URL(filePath: "/Arc/User Data/Profile 2")),
    ]
    @Shared(.profiles) var shared
    $shared.withLock { $0 = [Profile(id: UUID(200), name: "Default")] }
    let calls = LockIsolated<[String]>([])
    let store = TestStore(initialState: ImportFeature.State.arc(folder: URL(filePath: "/Arc"))) {
      ImportFeature()
    } withDependencies: {
      $0.browserImport.arcProfiles = { _ in profiles }
      $0.browserImport.safeStorageKey = { browser in
        calls.withValue { $0.append("key \(browser.rawValue)") }
        return Data("key".utf8)
      }
      $0.browserImport.passwords = { _, profile, _, into in
        calls.withValue { $0.append("passwords \(profile.name) \(into)") }
        return 1
      }
      $0.browserImport.cookies = { _, profile, _, into in
        calls.withValue { $0.append("cookies \(profile.name) \(into)") }
        return 6
      }
    }
    store.exhaustivity = .off

    await store.send(.arc(.delegate(.import(ArcData(), ArcShortcuts(), [.passwords, .cookies]))))
    await store.receive(\.finished) {
      $0.summary = ImportFeature.Summary(browser: .arc, passwords: 1, cookies: 6)
    }
    XCTAssertEqual(calls.value, ["key Arc", "passwords Personal \(UUID(200))", "cookies Personal \(UUID(200))"])
  }

  func testSafariPasswordsComeFromTheChosenFileAndItsCookiesNeedNoKey() async {
    let safari = BrowserSource(browser: .safari, profiles: [BrowserProfile(name: "", folder: URL(filePath: "/Safari"))])
    @Shared(.profiles) var shared
    $shared.withLock { $0 = [Profile(id: UUID(200), name: "Default")] }
    let calls = LockIsolated<[String]>([])
    var state = ImportFeature.State()
    state.sources = [safari]
    let store = TestStore(initialState: state) {
      ImportFeature()
    } withDependencies: {
      $0.browserImport.bookmarks = { _, _ in [] }
      $0.browserImport.history = { _, _, _ in 0 }
      $0.browserImport.cookies = { browser, _, key, into in
        calls.withValue { $0.append("cookies \(browser.rawValue) \(key == nil) \(into)") }
        return 8
      }
      $0.browserImport.passwordsFile = { file, into in
        calls.withValue { $0.append("file \(file.lastPathComponent) \(into)") }
        return 12
      }
    }
    store.exhaustivity = .off

    await store.send(.browserTapped(.safari))
    await store.receive(\.bookmarksLoaded)
    XCTAssertFalse(store.state.options!.includesPasswords)
    await store.send(.passwordsFileChosen(URL(filePath: "/tmp/Passwords.csv"))) {
      $0.options?.passwordsFile = URL(filePath: "/tmp/Passwords.csv")
      $0.options?.includesPasswords = true
    }
    var options = store.state.options!
    options.includesBookmarks = false
    await store.send(.binding(.set(\.options, options)))
    await store.send(.importTapped)
    await store.receive(\.finished) {
      $0.summary = ImportFeature.Summary(browser: .safari, passwords: 12, cookies: 8)
    }
    XCTAssertEqual(calls.value, ["cookies Safari true \(UUID(200))", "file Passwords.csv \(UUID(200))"])
  }

  func testBackFromTheStepItOpenedOnLeavesTheImport() async {
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: ImportFeature.State.arc(folder: URL(filePath: "/Arc"))) {
      ImportFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }
    await store.send(.arc(.cancelTapped))
    await store.receive(\.arc.delegate.cancel)
    XCTAssertTrue(dismissed.value)
  }
}
