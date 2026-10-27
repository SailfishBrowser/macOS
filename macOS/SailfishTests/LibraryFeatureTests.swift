import XCTest

@testable import Sailfish

final class LibraryFeatureTests: XCTestCase {
  private func download(_ name: String) -> Download {
    Download(
      id: name, url: URL(string: "https://sail.fish/\(name)")!, fileURL: URL(filePath: "/tmp/\(name)"),
      receivedBytes: 1, totalBytes: 1, state: .complete, startTime: Date(timeIntervalSince1970: 0))
  }

  func testASubtitleNamesTheKindOfFile() {
    XCTAssertEqual(download("a.pdf").subtitle, "PDF from sail.fish")
    XCTAssertEqual(download("a.png").subtitle, "Image from sail.fish")
    XCTAssertEqual(download("a.mp4").subtitle, "Video from sail.fish")
    XCTAssertEqual(download("a.zip").subtitle, "Download from sail.fish")
  }

  func testMediaFilesAreTheImagesAndVideosDirectlyInTheFoldersReadOnce() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder.appending(path: "nested"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["shot.png", "clip.mov", "notes.txt", ".hidden.png", "nested/deep.png"] {
      try Data().write(to: folder.appending(path: name))
    }

    let names = LibraryFeature.mediaFiles(in: [folder, folder.appending(path: "nested/..")], since: .distantPast).map(\.url.lastPathComponent).sorted()
    XCTAssertEqual(names, ["clip.mov", "shot.png"])
  }

  func testMediaFilesLeaveOutFilesCreatedBeforeTheFirstLaunch() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let firstLaunch = Date(timeIntervalSince1970: 1_000_000)
    for (name, created) in [("old.png", firstLaunch - 1), ("launch.png", firstLaunch), ("new.mov", firstLaunch + 60)] {
      let file = folder.appending(path: name)
      try Data().write(to: file)
      try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: file.path)
    }

    let names = LibraryFeature.mediaFiles(in: [folder], since: firstLaunch).map(\.url.lastPathComponent).sorted()
    XCTAssertEqual(names, ["launch.png", "new.mov"])
  }

  func testAFileSavedIntoAWatchedFolderIsReported() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var media = LibraryFeature.media(in: [folder], since: .distantPast).makeAsyncIterator()
    let first = await media.next()
    XCTAssertEqual(first?.isEmpty, true)
    // Dispatch registers the watch after the first read.
    try await Task.sleep(for: .milliseconds(200))

    try Data().write(to: folder.appending(path: "shot.png"))
    let next = await media.next()
    XCTAssertEqual(next?.map(\.url.lastPathComponent), ["shot.png"])
  }
}
