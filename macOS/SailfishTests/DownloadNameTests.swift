import XCTest

@testable import Sailfish

final class DownloadNameTests: XCTestCase {
  func testTidiesUnclearNames() {
    XCTAssertEqual(DownloadName.tidy("IMG_4821.jpg", site: "httpbin.org"), "Image from httpbin.jpg")
    XCTAssertEqual(
      DownloadName.tidy("export_2023-08-17T19-51-05_a8f3c2e1-4b6d-4e8f-9a1b-2c3d4e5f6a7b (3).csv", site: "httpbin.org"),
      "Export Aug 17 2023.csv")
    XCTAssertEqual(DownloadName.tidy("folio_option3_6691488.PDF", site: "httpbin.org"), "Folio Option3.PDF")
    XCTAssertEqual(DownloadName.tidy("download (3).zip", site: "httpbin.org"), "Download from httpbin.zip")
  }

  func testLeavesWellNamedFilesAlone() {
    XCTAssertNil(DownloadName.tidy("Quarterly Report.pdf", site: "httpbin.org"))
    XCTAssertNil(DownloadName.tidy("swift-chat-main.zip", site: "github.com"))
    XCTAssertNil(DownloadName.tidy("Sailfish-1.6.0.dmg", site: "sail.fish"))
    XCTAssertNil(DownloadName.tidy("README", site: nil))
  }

  func testCleansCruft() {
    XCTAssertEqual(DownloadName.tidy("Brooklyn_Bridge_September_2022.jpg", site: nil), "Brooklyn Bridge September 2022.jpg")
    XCTAssertEqual(DownloadName.tidy("Screenshot 2023-09-26 at 11.12.18 PM.png", site: nil), "Screenshot Sep 26 2023.png")
    XCTAssertEqual(DownloadName.tidy("PXL_20240105_143212.jpg", site: "photos.google.com"), "Image Jan 5 2024.jpg")
    XCTAssertEqual(DownloadName.tidy("annual%20report%20of%20the%20board.pdf", site: nil), "Annual Report of the Board.pdf")
    XCTAssertEqual(DownloadName.tidy("invoice-copy.pdf", site: nil), "Invoice.pdf")
    XCTAssertEqual(DownloadName.tidy("report_Xk9fQ2LmP0w.docx", site: nil), "Report.docx")
    XCTAssertEqual(DownloadName.tidy("8f3a2c1e9b7d.png", site: "www.bbc.co.uk"), "Image from bbc.png")
    XCTAssertEqual(DownloadName.tidy("untitled", site: nil), "Untitled")
  }

  func testUsesTheFilesOwnTitleWhenTheNameSaysNothing() {
    XCTAssertEqual(
      DownloadName.tidy("document (1).pdf", site: "a.example", title: "Mistral 7B"), "Mistral 7B.pdf")
    XCTAssertEqual(DownloadName.tidy("file.pdf", site: "a.example", title: "untitled"), "File from a.pdf")
  }

  func testUniqueNumbersTakenNames() {
    let taken: Set = ["Report.pdf", "Report 2.pdf"]
    XCTAssertEqual(DownloadName.unique("Report.pdf") { taken.contains($0) }, "Report 3.pdf")
    XCTAssertEqual(DownloadName.unique("Notes.txt") { taken.contains($0) }, "Notes.txt")
  }
}
