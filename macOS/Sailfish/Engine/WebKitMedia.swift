import AppKit
import WebKit

// What a frame's isolated script reports about its media.
enum MediaReport {
  // Whether the frame's media plays sound, counting media the tab's mute silences, and whether the frame is muted.
  case sound(audible: Bool, muted: Bool)
  // The frame's document, which reported media, went away.
  case gone
  // The frame's active media, nil once it has none worth controls: none, none started, or a clip of five seconds or
  // less without a media session.
  case nowPlaying(PageMedia?)
  case pictureInPicture(Bool)

  init?(_ kind: String, _ data: Any?) {
    let data = data as? [String: Any]
    switch kind {
    case "media":
      self = data.map { .sound(audible: $0["audible"] as? Bool == true, muted: $0["muted"] as? Bool == true) } ?? .gone
    case "nowPlaying":
      self = .nowPlaying(
        data.flatMap { data in
          guard data["controllable"] as? Bool == true else { return nil }
          let actions = data["actions"] as? [String] ?? []
          return PageMedia(
            isPlaying: data["playbackState"] as? String == "playing", hasVideo: data["hasVideo"] as? Bool == true,
            canPreviousTrack: actions.contains("previoustrack"), canNextTrack: actions.contains("nexttrack"),
            isInPictureInPicture: false)
        })
    case "pip": self = .pictureInPicture(data?["active"] as? Bool == true)
    default: return nil
    }
  }
}

// A WebKit page's media across its frames, as their scripts report it, and the tab's mute, which every frame with
// media follows.
struct WebKitMediaState {
  var isMuted = false
  // The frames that reported media, by the id their script gave itself, and those of them playing sound.
  var frames: [String: WKFrameInfo] = [:]
  var audibleFrames: Set<String> = []
  // The frame whose media the tab shows and controls, and that media.
  var nowPlayingFrame: String?
  var nowPlaying: PageMedia?
  var pictureInPictureFrame: String?
}

extension WebKitPage {
  var isAudible: Bool { !mediaState.audibleFrames.isEmpty }

  var media: PageMedia? {
    guard var media = mediaState.nowPlaying else { return nil }
    media.isInPictureInPicture = mediaState.pictureInPictureFrame != nil
    return media
  }

  var isMuted: Bool {
    get { mediaState.isMuted }
    set {
      mediaState.isMuted = newValue
      run(muteScript, in: nil)
      for frame in mediaState.frames.values where !frame.isMainFrame {
        run(muteScript, in: frame)
      }
      onUpdate?(self)
    }
  }

  private var muteScript: String { "window.__sailfish && window.__sailfish.mute(\(mediaState.isMuted))" }

  func receive(_ report: MediaReport, frame: String, from info: WKFrameInfo) {
    switch report {
    case let .sound(audible, muted):
      mediaState.frames[frame] = info
      if muted != mediaState.isMuted {
        run(muteScript, in: info)
      }
      if audible {
        mediaState.audibleFrames.insert(frame)
      } else {
        mediaState.audibleFrames.remove(frame)
      }
    case .gone:
      mediaState.frames[frame] = nil
      mediaState.audibleFrames.remove(frame)
      if mediaState.nowPlayingFrame == frame {
        mediaState.nowPlayingFrame = nil
        mediaState.nowPlaying = nil
      }
      if mediaState.pictureInPictureFrame == frame {
        mediaState.pictureInPictureFrame = nil
      }
    // Another frame's media takes the controls when it plays, or when the media they show does not.
    case let .nowPlaying(media?):
      mediaState.frames[frame] = info
      if frame == mediaState.nowPlayingFrame || media.isPlaying || mediaState.nowPlaying?.isPlaying != true {
        mediaState.nowPlayingFrame = frame
        mediaState.nowPlaying = media
      }
    case .nowPlaying(nil):
      guard mediaState.nowPlayingFrame == frame else { return }
      mediaState.nowPlayingFrame = nil
      mediaState.nowPlaying = nil
    case let .pictureInPicture(active):
      mediaState.frames[frame] = info
      if active {
        mediaState.pictureInPictureFrame = frame
      } else if mediaState.pictureInPictureFrame == frame {
        mediaState.pictureInPictureFrame = nil
      }
    }
    onUpdate?(self)
  }

  // A new document in the main frame: its frames report their media afresh, and the tab's mute applies to it.
  func mediaDidCommit() {
    mediaState = WebKitMediaState(isMuted: mediaState.isMuted)
    if mediaState.isMuted {
      run(muteScript, in: nil)
    }
  }

  // Play and pause go to the page's own media session handlers when it has them, and to the active media element
  // otherwise; previous and next go to the handlers. Picture in Picture takes the playing video, or the largest.
  func perform(_ command: MediaCommand) {
    let frame = mediaState.nowPlayingFrame.flatMap { mediaState.frames[$0] }
    switch command {
    case .play: run("window.__sailfish && window.__sailfish.media('play')", in: frame)
    case .pause: run("window.__sailfish && window.__sailfish.media('pause')", in: frame)
    case .previousTrack: run("window.__sailfish && window.__sailfish.media('previous')", in: frame)
    case .nextTrack: run("window.__sailfish && window.__sailfish.media('next')", in: frame)
    case .enterPictureInPicture: run("window.__sailfish && window.__sailfish.pictureInPicture(true)", in: frame)
    case .exitPictureInPicture:
      run(
        "window.__sailfish && window.__sailfish.pictureInPicture(false)",
        in: mediaState.pictureInPictureFrame.flatMap { mediaState.frames[$0] })
    }
  }

  // Runs a script in Sailfish's content world in the frame, or in the main frame for none.
  private func run(_ script: String, in frame: WKFrameInfo?) {
    webView.evaluateJavaScript(script, in: frame?.isMainFrame == false ? frame : nil, in: WebKitPageScript.world)
  }
}

extension Engine {
  func setMuted(_ tab: UUID, _ muted: Bool) {
    page(tab)?.isMuted = muted
  }
}
