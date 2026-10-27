import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class DownloadsFeatureTests: XCTestCase {
  let download = Download(
    id: "0/1", url: URL(string: "https://a.example/table.pdf")!, fileURL: URL(filePath: "/tmp/table.pdf"),
    receivedBytes: 10, totalBytes: 10, state: .complete, startTime: Date(timeIntervalSince1970: 1_000))

  func testHideRemovesTheDownloadAndKeepsItHidden() async {
    let store = TestStore(initialState: DownloadsFeature.State(downloads: [download])) { DownloadsFeature() }

    await store.send(.hide(download.id)) {
      $0.downloads = []
      $0.$hidden.withLock { $0 = [self.download.hiddenKey] }
    }
    // The engine reports it again on the next launch, under whatever ID its profile gets.
    await store.send(.updated(Download(
      id: "1/1", url: download.url, fileURL: download.fileURL, receivedBytes: 10, totalBytes: 10, state: .complete,
      startTime: download.startTime)))
  }

  func testMoveToTrashTrashesTheFileThenHidesIt() async {
    let trashed = LockIsolated<[URL]>([])
    let store = TestStore(initialState: DownloadsFeature.State(downloads: [download])) {
      DownloadsFeature()
    } withDependencies: {
      $0.trashFile = { url in trashed.withValue { $0.append(url) } }
    }

    await store.send(.moveToTrash(download.id))
    await store.receive(\.hide) {
      $0.downloads = []
      $0.$hidden.withLock { $0 = [self.download.hiddenKey] }
    }
    XCTAssertEqual(trashed.value, [download.fileURL!])
  }

  func testAFinishedDownloadShowsOnTheLibraryButtonForHalfAMinute() async {
    var running = download
    running.state = .inProgress
    let clock = TestClock()
    let store = TestStore(initialState: DownloadsFeature.State(downloads: [running])) {
      DownloadsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.tidyDownload = { _, _ in nil }
    }

    await store.send(.updated(download)) {
      $0.downloads[id: self.download.id] = self.download
      $0.finished = self.download.id
    }
    await clock.advance(by: .seconds(29))
    await clock.advance(by: .seconds(1))
    await store.receive(\.finishedShown) { $0.finished = nil }
  }

  func testTheNextFinishedDownloadTakesTheButtonAndRestartsItsHalfMinute() async {
    var first = download
    first.state = .inProgress
    var second = Download(
      id: "0/2", url: URL(string: "https://a.example/b.zip")!, fileURL: URL(filePath: "/tmp/b.zip"),
      receivedBytes: 1, totalBytes: 10, state: .inProgress, startTime: Date(timeIntervalSince1970: 2_000))
    let clock = TestClock()
    let store = TestStore(initialState: DownloadsFeature.State(downloads: [second, first])) {
      DownloadsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.tidyDownload = { _, _ in nil }
    }

    await store.send(.updated(download)) {
      $0.downloads[id: self.download.id] = self.download
      $0.finished = self.download.id
    }
    await clock.advance(by: .seconds(20))
    second.receivedBytes = 10
    second.state = .complete
    await store.send(.updated(second)) {
      $0.downloads[id: second.id] = second
      $0.finished = second.id
    }
    await clock.advance(by: .seconds(29))
    await clock.advance(by: .seconds(1))
    await store.receive(\.finishedShown) { $0.finished = nil }
  }

  func testAFinishedDownloadIsRenamedAndKeepsItsNewNameWhenReportedAgain() async {
    var running = download
    running.state = .inProgress
    let renamed = URL(filePath: "/tmp/Table.pdf")
    let clock = TestClock()
    let store = TestStore(initialState: DownloadsFeature.State(downloads: [running])) {
      DownloadsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.tidyDownload = { file, site in
        XCTAssertEqual(file, self.download.fileURL)
        XCTAssertEqual(site, "a.example")
        return renamed
      }
    }

    await store.send(.updated(download)) {
      $0.downloads[id: self.download.id] = self.download
      $0.finished = self.download.id
    }
    await store.receive(\.renamed) {
      $0.$renamed.withLock { $0 = [self.download.hiddenKey: "Table.pdf"] }
      $0.downloads[id: self.download.id]?.fileURL = renamed
      $0.downloads[id: self.download.id]?.originalName = "table.pdf"
    }
    // The engine only knows the name it downloaded under.
    await store.send(.updated(download))
    await clock.advance(by: .seconds(30))
    await store.receive(\.finishedShown) { $0.finished = nil }
  }

  func testWithTidyDownloadsOffAFinishedDownloadKeepsItsName() async {
    var running = download
    running.state = .inProgress
    var state = DownloadsFeature.State(downloads: [running])
    state.$tidiesNames.withLock { $0 = false }
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      DownloadsFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(.updated(download)) {
      $0.downloads[id: self.download.id] = self.download
      $0.finished = self.download.id
    }
    await clock.advance(by: .seconds(30))
    await store.receive(\.finishedShown) { $0.finished = nil }
  }

  func testRevertingMovesTheFileBackAndForgetsTheName() async {
    var renamed = download
    renamed.fileURL = URL(filePath: "/tmp/Table.pdf")
    renamed.originalName = "table.pdf"
    var state = DownloadsFeature.State(downloads: [renamed])
    state.$renamed.withLock { $0 = [self.download.hiddenKey: "Table.pdf"] }
    let moves = LockIsolated<[[URL]]>([])
    let store = TestStore(initialState: state) {
      DownloadsFeature()
    } withDependencies: {
      $0.moveFile = { from, to in moves.withValue { $0.append([from, to]) } }
    }

    await store.send(.revertName(download.id))
    await store.receive(\.reverted) {
      $0.$renamed.withLock { $0 = [:] }
      $0.downloads[id: self.download.id] = self.download
    }
    XCTAssertEqual(moves.value, [[URL(filePath: "/tmp/Table.pdf"), URL(filePath: "/tmp/table.pdf")]])
  }
}
