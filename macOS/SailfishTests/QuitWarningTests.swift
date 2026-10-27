import XCTest

@testable import Sailfish

@MainActor
final class QuitWarningTests: XCTestCase {
  func testAsksBeforeQuittingByDefault() {
    XCTAssertEqual(QuitWarning.prompt(bypass: false, isSystemQuit: false, isDownloading: false, isEnabled: true), .confirm)
  }

  func testQuitsWithoutAskingWhenTurnedOff() {
    XCTAssertEqual(QuitWarning.prompt(bypass: false, isSystemQuit: false, isDownloading: false, isEnabled: false), .none)
  }

  func testAsksAboutDownloadsEvenWhenTurnedOff() {
    XCTAssertEqual(QuitWarning.prompt(bypass: false, isSystemQuit: false, isDownloading: true, isEnabled: true), .downloads)
    XCTAssertEqual(QuitWarning.prompt(bypass: false, isSystemQuit: false, isDownloading: true, isEnabled: false), .downloads)
  }

  func testUpdaterRelaunchAndLogoutNeverWait() {
    for isDownloading in [false, true] {
      XCTAssertEqual(
        QuitWarning.prompt(bypass: true, isSystemQuit: false, isDownloading: isDownloading, isEnabled: true), .none)
      XCTAssertEqual(
        QuitWarning.prompt(bypass: false, isSystemQuit: true, isDownloading: isDownloading, isEnabled: true), .none)
    }
  }
}
