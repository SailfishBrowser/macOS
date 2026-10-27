import AppKit
@preconcurrency import EngineCore

// The page's media while it has any, playing or paused, as Chrome's media session sees it.
struct PageMedia: Equatable, Sendable {
  var isPlaying: Bool
  var hasVideo: Bool
  var canPreviousTrack: Bool
  var canNextTrack: Bool
  var isInPictureInPicture: Bool
}

enum MediaCommand: Equatable, Sendable {
  case play, pause, previousTrack, nextTrack
  // Moves the playing video into Chrome's Picture in Picture window, placed over the top right of the key window.
  case enterPictureInPicture
  case exitPictureInPicture
}

extension ECWebContents {
  var media: PageMedia? {
    guard hasMedia else { return nil }
    return PageMedia(
      isPlaying: isPlayingMedia, hasVideo: mediaHasVideo, canPreviousTrack: canGoToPreviousTrack,
      canNextTrack: canGoToNextTrack, isInPictureInPicture: pictureInPictureWindow != nil)
  }
}

// The Picture in Picture window: 300 pt wide, 10 pt in from the top right of the window the tab was left in.
@MainActor
enum PictureInPicture {
  private static var anchors: [UUID: NSWindow] = [:]
  private static let width: CGFloat = 300
  private static let inset: CGFloat = 10

  static func perform(_ command: MediaCommand, on tab: UUID) {
    Engine.shared.perform(tab) { contents in
      switch command {
      case .play: contents.playMedia()
      case .pause: contents.pauseMedia()
      case .previousTrack: contents.previousTrack()
      case .nextTrack: contents.nextTrack()
      case .enterPictureInPicture:
        anchors[tab] = NSApp.keyWindow
        contents.enterPictureInPicture()
      case .exitPictureInPicture: contents.exitPictureInPicture()
      }
    }
  }

  // Places the window once, as it opens; it is the user's to move after.
  static func place(_ contents: ECWebContents, of tab: UUID) {
    guard let window = contents.pictureInPictureWindow else { return }
    guard let anchor = anchors.removeValue(forKey: tab)?.frame, window.frame.width > 0 else { return }
    let height = (window.frame.height / window.frame.width * width).rounded()
    window.setFrame(
      NSRect(x: anchor.maxX - inset - width, y: anchor.maxY - inset - height, width: width, height: height),
      display: true)
  }
}

// A tab's volume is the volume of the page's own audio and video elements, read from the one playing.
enum MediaVolume {
  static let read = """
    (() => {
      const all = [...document.querySelectorAll('audio, video')];
      const media = all.find(m => !m.paused) ?? all[0];
      return media ? String(media.volume) : null;
    })()
    """

  static func set(_ volume: Double) -> String {
    "document.querySelectorAll('audio, video').forEach(m => m.volume = \(volume))"
  }

  static func symbol(_ volume: Double) -> String {
    switch volume {
    case 0: "speaker.fill"
    case ..<(1.0 / 3): "speaker.wave.1.fill"
    case ..<(2.0 / 3): "speaker.wave.2.fill"
    default: "speaker.wave.3.fill"
    }
  }
}

extension Engine {
  func mediaVolume(_ tab: UUID, _ done: @escaping @MainActor (Double) -> Void) {
    tabs[tab]?.evaluateJavaScript(MediaVolume.read) { result in
      MainActor.assumeIsolated { result.flatMap(Double.init).map(done) }
    }
  }

  func setMediaVolume(_ tab: UUID, _ volume: Double) {
    tabs[tab]?.evaluateJavaScript(MediaVolume.set(volume)) { _ in }
  }

  func webContentsDidRequestActivation(_ contents: ECWebContents) {
    guard let tab = tab(of: contents) else { return }
    Self.continuation.yield(.activateRequested(tab: tab))
  }
}
