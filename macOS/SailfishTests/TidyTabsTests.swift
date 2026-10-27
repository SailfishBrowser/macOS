import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class TidyTabsTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)

  private func space(_ pages: [(String, String)]) -> Space {
    var space = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    space.tabs = IdentifiedArray(uniqueElements: pages.enumerated().map {
      Tab(
        id: UUID(50 + $0.offset), url: URL(string: $0.element.0)!, title: $0.element.1, placement: .unpinned,
        createdAt: now, lastActiveAt: now)
    })
    return space
  }

  private func tabs(_ pages: [(String, String)]) -> [TidyTab] {
    pages.enumerated().map { TidyTab(id: UUID($0.offset), title: $0.element.1, host: URL(string: $0.element.0)!.host()!) }
  }

  private func groups(_ pages: [(String, String)]) -> [String: [Int]] {
    Dictionary(uniqueKeysWithValues: sortIntoGroups(tabs(pages)).map { group in
      (group.name, group.tabIDs.map { id in tabs(pages).firstIndex { $0.id == id }! })
    })
  }

  func testTidyGroupsTheTodayTabsAndSweeps() async {
    let clock = TestClock()
    let store = TestStore(
      initialState: space([
        ("https://github.com/apple/swift/issues", "Issues · apple/swift · GitHub"),
        ("https://cooking.nytimes.com/1", "Chicken Curry - NYT Cooking"),
        ("https://github.com/pulls", "Pull requests · GitHub"),
        ("https://www.seriouseats.com/2", "Chicken Tikka Masala - Serious Eats"),
        ("https://news.ycombinator.com/", "Hacker News"),
      ])
    ) {
      TabsFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.uuid = .incrementing
      $0.continuousClock = clock
    }
    await store.send(.tidy(.start)) { state in
      state.isTidying = true
      state.groups = [
        TabGroup(id: UUID(0), name: "GitHub", color: .grey), TabGroup(id: UUID(1), name: "Chicken", color: .blue),
      ]
      for id in [50, 52] { state.tabs[id: UUID(id)]?.groupID = UUID(0) }
      for id in [51, 53] { state.tabs[id: UUID(id)]?.groupID = UUID(1) }
      state.ownTabs = IdentifiedArray(uniqueElements: [50, 52, 51, 53, 54].map { state.tabs[id: UUID($0)]! })
    }
    await store.receive(\.delegate.moved)
    await clock.advance(by: TabsFeature.sweep)
    await store.receive(\.tidy.swept) {
      $0.isTidying = false
    }
  }

  func testGroupedTabsAreLeftOutAndNothingToGroupSaysSo() async {
    var space = space([
      ("https://site.example/1", "Page 1"), ("https://site.example/2", "Page 2"), ("https://other.example/", "Page 3"),
    ])
    space.groups = [TabGroup(id: UUID(10), name: "Work", color: .grey)]
    space.tabs[id: UUID(51)]?.groupID = UUID(10)
    let clock = TestClock()
    let store = TestStore(initialState: space) {
      TabsFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.continuousClock = clock
    }
    await store.send(.tidy(.start)) {
      $0.isTidying = true
    }
    await store.receive(\.delegate.tidyMessage, "No tab groups found")
    await clock.advance(by: TabsFeature.sweep)
    await store.receive(\.tidy.swept) {
      $0.isTidying = false
    }
  }

  func testSitesAreNamedAsTheirTitlesNameThem() {
    XCTAssertEqual(
      groups([
        ("https://mail.google.com/a", "Inbox (3) - me@example.com - Gmail"),
        ("https://docs.google.com/b", "Budget - Google Sheets"),
        ("https://www.youtube.com/c", "Lo-fi beats - YouTube"),
        ("https://mail.google.com/d", "Sent Mail - me@example.com - Gmail"),
        ("https://youtube.com/e", "Cat compilation - YouTube"),
        ("https://www.bbc.co.uk/f", "BBC News - Home"),
        ("https://www.bbc.co.uk/g", "Weather - BBC"),
        ("https://www.example.com/h", "First"),
        ("https://example.com/i", "Second"),
      ]),
      ["Gmail": [0, 3], "YouTube": [2, 4], "BBC": [5, 6], "Example": [7, 8]])
  }

  func testTabsOfDifferentSitesShareATopic() {
    XCTAssertEqual(
      groups([
        ("https://www.theverge.com/1", "iPhone 18 review: the best phone - The Verge"),
        ("https://www.google.com/travel/flights", "Flights to Tokyo - Google Flights"),
        ("https://www.youtube.com/2", "Apple iPhone 18 Pro hands-on - YouTube"),
        ("https://www.booking.com/3", "Tokyo Hotels - Booking.com"),
        ("https://www.espn.com/4", "Lakers vs Celtics - ESPN"),
        ("https://www.wikipedia.org/5", "The Best Of Everything - Wikipedia"),
      ]),
      ["iPhone": [0, 2], "Tokyo": [1, 3]])
  }

  func testGroupsFollowTheTabOrder() {
    let pages = [
      ("https://b.example/1", "One"), ("https://a.example/1", "Two"), ("https://b.example/2", "Three"),
      ("https://a.example/2", "Four"),
    ]
    XCTAssertEqual(sortIntoGroups(tabs(pages)).map(\.name), ["B", "A"])
    XCTAssertTrue(sortIntoGroups(tabs(Array(pages.prefix(2)))).isEmpty)
  }
}
