import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class FavoritePreviewTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)
  let gmail = URL(string: "https://mail.google.com/mail/u/0/#inbox")!

  func testPreloadLoadsAFavoritesPageWithoutShowingIt() async {
    @Shared(.profiles) var profiles = [Profile(id: UUID(200), name: "Default")]
    var space = Space(id: UUID(100), name: "Space 1", profileID: UUID(200), createdAt: now)
    space.tabs = [Tab(id: UUID(50), url: gmail, title: "Gmail", placement: .favorite, pinnedURL: gmail, createdAt: now, lastActiveAt: now)]
    let loaded = LockIsolated<[URL]>([])
    let store = TestStore(initialState: space) {
      TabsFeature()
    } withDependencies: {
      $0.webEngine.create = { _, _, _, _, _ in }
      $0.webEngine.load = { _, url in loaded.withValue { $0.append(url) } }
    }

    await store.send(.preload(UUID(50))) {
      $0.tabs[id: UUID(50)]?.isLive = true
    }
    await store.send(.preload(UUID(50)))
    XCTAssertEqual(loaded.value, [gmail])
    XCTAssertNil(store.state.selectedTabID)
  }

  func testPreviewAppsComeFromTheFavoritesHost() {
    XCTAssertEqual(PreviewApp(gmail), .gmail)
    XCTAssertEqual(PreviewApp(URL(string: "https://calendar.google.com/calendar/u/0/r/week")!), .calendar)
    XCTAssertNil(PreviewApp(URL(string: "https://notion.so")!))
  }

  func testGmailsUnreadCountIsReadFromItsTitle() {
    XCTAssertEqual(PreviewApp.unreadCount("Inbox (3) - me@example.com - Gmail"), 3)
    XCTAssertEqual(PreviewApp.unreadCount("Inbox (1,204) - me@example.com - Gmail"), 1204)
    XCTAssertNil(PreviewApp.unreadCount("Inbox - me@example.com - Gmail"))
    XCTAssertNil(PreviewApp.unreadCount("Lunch - Ada (2) - Gmail"))
  }

  func testExtractorResultsDecodeAndAMismatchIsNil() {
    let json = #"[{"id":"1","title":"Ada","subtitle":"Hello","url":"https://mail.google.com/mail/u/0?message_id=1"},{"id":"2","title":"Sync","subtitle":"10am","url":null}]"#
    XCTAssertEqual(PreviewApp.items(json), [
      PreviewItem(id: "1", title: "Ada", subtitle: "Hello", url: URL(string: "https://mail.google.com/mail/u/0?message_id=1")),
      PreviewItem(id: "2", title: "Sync", subtitle: "10am", url: nil),
    ])
    XCTAssertEqual(PreviewApp.items("[]"), [])
    XCTAssertNil(PreviewApp.items(nil))
  }

  func testCalendarEventTimesPlaceOnTheDay() {
    XCTAssertEqual(PreviewApp.span("10am to 11:30am"), 600..<690)
    XCTAssertEqual(PreviewApp.span("10 to 11am"), 600..<660)
    XCTAssertEqual(PreviewApp.span("12pm to 1:15pm"), 720..<795)
    XCTAssertEqual(PreviewApp.span("11pm to 12:30am"), 1380..<1470)
    XCTAssertNil(PreviewApp.span("All day"))
  }
}
