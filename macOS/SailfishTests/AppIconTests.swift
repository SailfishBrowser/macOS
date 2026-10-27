import XCTest

@testable import Sailfish

final class AppIconTests: XCTestCase {
  func testEveryAlternateIconShipsEverySize() {
    for icon in AppIcon.allCases where icon != .original {
      let widths = Set(icon.image().representations.map(\.pixelsWide))
      XCTAssertEqual(widths, [16, 32, 64, 128, 256, 512, 1024], icon.rawValue)
    }
  }
}
