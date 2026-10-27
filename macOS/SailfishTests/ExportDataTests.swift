import ComposableArchitecture
import XCTest

@testable import Sailfish

final class ExportDataTests: XCTestCase {
  func testMarkdownListsFavoritesPinnedFoldersAndToday() {
    let now = Date(timeIntervalSince1970: 1_000)
    func tab(_ n: Int, _ placement: Placement, title: String = "") -> Tab {
      Tab(
        id: UUID(n), url: URL(string: "https://\(n).example")!, title: title, placement: placement, createdAt: now,
        lastActiveAt: now)
    }
    @Shared(.profiles) var profiles = [Profile(id: UUID(200), name: "Default")]
    var space = Space(id: UUID(100), name: "Work", profileID: UUID(200), createdAt: now)
    let folder = Folder(id: UUID(50), name: "Docs")
    space.folders = [folder]
    space.tabs = [tab(1, .favorite, title: "Mail"), tab(2, .pinned, title: "Board [v2] \\"), tab(3, .folder(folder.id), title: "Spec"), tab(4, .unpinned)]
    space.pinnedOrder = [UUID(2), UUID(50)]

    XCTAssertEqual(
      ExportData.markdown([space]),
      """
      # Spaces

      ## Work

      ### Favorites

      - [Mail](<https://1.example>)

      ### Pinned

      - [Board \\[v2\\] \\\\](<https://2.example>)
      - **Docs**
        - [Spec](<https://3.example>)

      ### Today

      - [https://4.example](<https://4.example>)

      """)
  }
}
