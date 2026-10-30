import ComposableArchitecture
import XCTest

@testable import Sailfish

@MainActor
final class MiniPlayerTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_000)

  func tab(_ id: Int, media: PageMedia? = nil) -> Tab {
    var tab = Tab(
      id: UUID(id), url: URL(string: "https://\(id).example")!, title: "\(id)", placement: .unpinned, createdAt: now,
      lastActiveAt: now)
    tab.isLive = true
    tab.media = media
    return tab
  }

  func media(playing: Bool = true, video: Bool = false, inPictureInPicture: Bool = false) -> PageMedia {
    PageMedia(
      isPlaying: playing, hasVideo: video, canPreviousTrack: false, canNextTrack: false,
      isInPictureInPicture: inPictureInPicture)
  }

  func store(_ tabs: [Tab], commands: LockIsolated<[MediaCommand]>) -> TestStoreOf<WindowFeature> {
    var space = Space(id: UUID(1), name: "Home", profileID: UUID(200), createdAt: now)
    space.tabs = IdentifiedArray(uniqueElements: tabs)
    space.selectedTabID = tabs.first?.id
    let store = TestStore(
      initialState: WindowFeature.State(id: UUID(3), sidebar: .init(), spaces: .init(spaces: [space], selectedID: space.id))
    ) {
      WindowFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.webEngine.create = { _, _, _, _, _, _ in }
      $0.webEngine.load = { _, _ in }
      $0.webEngine.media = { _, command in commands.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off
    return store
  }

  func testLeavingATabPlayingSoundShowsItsControlsUntilItIsShownAgain() async {
    let commands = LockIsolated<[MediaCommand]>([])
    let store = store([tab(10, media: media()), tab(11)], commands: commands)

    await store.send(.tab(.select(UUID(11)), in: UUID(1))) { $0.miniPlayer = UUID(10) }
    await store.send(.tab(.select(UUID(10)), in: UUID(1))) { $0.miniPlayer = nil }
    XCTAssertEqual(commands.value, [])
  }

  func testLeavingATabPlayingVideoMovesItIntoPictureInPicture() async {
    let commands = LockIsolated<[MediaCommand]>([])
    let store = store([tab(10, media: media(video: true)), tab(11)], commands: commands)

    await store.send(.tab(.select(UUID(11)), in: UUID(1)))
    await store.finish()
    XCTAssertNil(store.state.miniPlayer)
    XCTAssertEqual(commands.value, [.enterPictureInPicture])
  }

  func testShowingATabInPictureInPictureEndsIt() async {
    let commands = LockIsolated<[MediaCommand]>([])
    let store = store([tab(11), tab(10, media: media(video: true, inPictureInPicture: true))], commands: commands)

    await store.send(.tab(.select(UUID(10)), in: UUID(1)))
    await store.finish()
    XCTAssertEqual(commands.value, [.exitPictureInPicture])
  }

  func testLeavingPausedMediaShowsNothing() async {
    let commands = LockIsolated<[MediaCommand]>([])
    let store = store([tab(10, media: media(playing: false)), tab(11, media: media(playing: false, video: true))], commands: commands)

    await store.send(.tab(.select(UUID(11)), in: UUID(1)))
    await store.send(.tab(.select(UUID(10)), in: UUID(1)))
    await store.finish()
    XCTAssertNil(store.state.miniPlayer)
    XCTAssertEqual(commands.value, [])
  }

  func testClosingTheMiniPlayerLeavesTheTabPlaying() async {
    let commands = LockIsolated<[MediaCommand]>([])
    let store = store([tab(10, media: media()), tab(11)], commands: commands)

    await store.send(.tab(.select(UUID(11)), in: UUID(1))) { $0.miniPlayer = UUID(10) }
    await store.send(.closeMiniPlayer) { $0.miniPlayer = nil }
    XCTAssertEqual(commands.value, [])
  }

  func testTheSpeakerShowsTheTabsVolumeAsArcsDoes() {
    XCTAssertEqual(
      [0, 0.3, 0.5, 1].map(MediaVolume.symbol),
      ["speaker.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"])
  }
}
