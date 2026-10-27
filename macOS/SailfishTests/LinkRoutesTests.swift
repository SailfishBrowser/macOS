import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class LinkRoutesTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)
  let work = UUID(100)
  let home = UUID(101)
  let other = UUID(102)

  func route(_ match: LinkRoutes.Match, _ text: String, _ destination: LinkRoutes.Destination) -> LinkRoutes.Route {
    LinkRoutes.Route(id: UUID(), match: match, text: text, destination: destination)
  }

  func testTheFirstMatchingRouteWins() {
    let routes = LinkRoutes(
      routes: [
        route(.isEqualTo, "https://spotify.com/", .space(work)),
        route(.contains, "", .space(home)),
        route(.contains, "SPOTIFY", .space(home)),
        route(.contains, "spotify.com", .littleSailfish),
      ],
      defaultDestination: .mostRecentSpace)
    let spaces: Set = [work, home]

    XCTAssertEqual(routes.destination(for: URL(string: "https://Spotify.com/")!, spaces: spaces), .space(work))
    XCTAssertEqual(routes.destination(for: URL(string: "https://open.spotify.com/track/1")!, spaces: spaces), .space(home))
    XCTAssertEqual(routes.destination(for: URL(string: "https://example.com/")!, spaces: spaces), .mostRecentSpace)
  }

  func testRoutesAndADefaultToASpaceThatIsGoneArePassedOver() {
    let routes = LinkRoutes(
      routes: [route(.contains, "example", .space(other)), route(.contains, "example.com", .space(work))],
      defaultDestination: .space(other))

    XCTAssertEqual(routes.destination(for: URL(string: "https://example.com/")!, spaces: [work]), .space(work))
    XCTAssertEqual(routes.destination(for: URL(string: "https://example.org/")!, spaces: [work]), .mostRecentSpace)
  }

  func testArcsMeetRouteSendsMeetLinksToTheMostRecentSpace() {
    let routes = LinkRoutes.initial
    XCTAssertEqual(routes.destination(for: URL(string: "https://meet.google.com/abc")!, spaces: []), .mostRecentSpace)
    XCTAssertEqual(routes.destination(for: URL(string: "https://example.com/")!, spaces: []), .littleSailfish)
  }

  // A routed link opens as a new tab of its space, which its window selects; the rest go to the default.
  func testLinksFromOtherAppsOpenWhereTheyAreRouted() async {
    let profile = UUID(200)
    let workSpace = Space(id: work, name: "Work", profileID: profile, createdAt: now)
    let homeSpace = Space(id: home, name: "Home", profileID: profile, createdAt: now)
    let otherSpace = Space(id: other, name: "Other", profileID: profile, createdAt: now)
    let state = AppFeature.State(
      windows: [
        WindowFeature.State(id: UUID(300), sidebar: .init(), spaces: .init(spaces: [workSpace, homeSpace], selectedID: work)),
        WindowFeature.State(id: UUID(301), sidebar: .init(), spaces: .init(spaces: [otherSpace], selectedID: other)),
      ],
      isLoaded: true, pendingURLs: nil)
    state.$profiles.withLock { $0 = [Profile(id: profile, name: "Default")] }
    state.$linkRoutes.withLock {
      $0 = LinkRoutes(
        routes: [route(.contains, "spotify.com", .space(home)), route(.contains, "meet.google.com", .mostRecentSpace)],
        defaultDestination: .littleSailfish)
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(now)
      $0.continuousClock = ImmediateClock()
      $0.persistence.save = { _ in }
      $0.webEngine.create = { _, _, _ in }
      $0.webEngine.load = { _, _ in }
      $0.webEngine.saveSessions = {}
      $0.webEngine.keepSessions = { _ in }
    }
    store.exhaustivity = .off

    let spotify = URL(string: "https://open.spotify.com/track/1")!
    let meet = URL(string: "https://meet.google.com/abc")!
    let page = URL(string: "https://example.com/")!
    await store.send(.openURLs([spotify, meet, page]))
    await store.skipReceivedActions()

    let windows = store.state.windows
    XCTAssertEqual(windows[id: UUID(300)]?.spaces.selectedID, home)
    XCTAssertEqual(windows[id: UUID(300)]?.spaces.spaces[id: home]?.tabs.map(\.url), [spotify])
    XCTAssertEqual(windows[id: UUID(300)]?.spaces.spaces[id: work]?.tabs.map(\.url), [])
    XCTAssertEqual(windows[id: UUID(301)]?.spaces.spaces[id: other]?.tabs.map(\.url), [meet])
    XCTAssertEqual(store.state.littleSailfishes.map(\.tab?.url), [page])

    // Off, the Links toggle sends the rest to the most recent space.
    store.state.$linkRoutes.withLock { $0.defaultDestination = .mostRecentSpace }
    await store.send(.openURLs([page]))
    await store.skipReceivedActions()
    XCTAssertEqual(store.state.windows[id: UUID(301)]?.spaces.spaces[id: other]?.tabs.map(\.url), [page, meet])
    XCTAssertEqual(store.state.littleSailfishes.count, 1)
  }
}
