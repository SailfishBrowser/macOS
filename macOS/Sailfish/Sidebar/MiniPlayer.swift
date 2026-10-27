import ComposableArchitecture
import SwiftUI

extension WindowFeature {
  // Leaving a tab whose video plays moves the video into Picture in Picture, and leaving one that plays
  // only sound shows its controls at the foot of the sidebar. Showing the tab again ends either.
  func miniPlayerFollows(_ state: inout State, shown: Tab.ID?, selected: Tab.ID?) -> Effect<Action> {
    func media(_ id: Tab.ID) -> PageMedia? {
      state.spaces.spaces.lazy.compactMap { $0.tabs[id: id] }.first?.media
    }
    if state.miniPlayer == selected {
      state.miniPlayer = nil
    }
    var effects: [Effect<Action>] = []
    if let selected, media(selected)?.isInPictureInPicture == true {
      effects.append(.run { _ in await engine.media(selected, .exitPictureInPicture) })
    }
    if let shown, shown != selected, let left = media(shown), left.isPlaying {
      if !left.hasVideo {
        state.miniPlayer = shown
      } else if !left.isInPictureInPicture {
        effects.append(.run { _ in await engine.media(shown, .enterPictureInPicture) })
      }
    }
    return .merge(effects)
  }
}

// The mini player: a tab's favicon (back to the tab), previous, play or pause, next and the tab's volume. Hovering it
// shows the tab's title and a close button above; the speaker opens a volume slider below until the pointer leaves.
// It goes once the page has no media.
struct MiniPlayer: View {
  let store: StoreOf<WindowFeature>
  @State private var isHovering = false
  @State private var showsVolume = false
  @State private var volume = 1.0

  var body: some View {
    if let id = store.miniPlayer, let space = store.spaces.spaces.first(where: { $0.tabs[id: id] != nil }),
      let tab = space.tabs[id: id], let media = tab.media
    {
      VStack(spacing: 0) {
        if isHovering {
          HStack(spacing: 0) {
            Text(tab.displayTitle).font(.system(size: 13)).foregroundStyle(Color(hex: 0xCDCDD4)).lineLimit(1)
            Spacer(minLength: 8)
            control("xmark", "Close Mini Player") { store.send(.closeMiniPlayer) }
              .frame(width: 40)
          }
          .padding(.leading, 14)
          .frame(height: 33)
          .transition(.opacity)
        }
        HStack(spacing: 0) {
          Button { store.send(.openFromLibrary(space.id, tab: id)) } label: {
            TabFavicon(tab: tab, space: space).frame(width: 24, height: 24).contentShape(Rectangle())
          }
          .buttonStyle(MiniPlayerButtonStyle())
          .hoverTooltip("Back to Tab")
          .frame(maxWidth: .infinity)
          control("backward.end.fill", "Previous Track", isEnabled: media.canPreviousTrack) {
            PictureInPicture.perform(.previousTrack, on: id)
          }
          control(media.isPlaying ? "pause.fill" : "play.fill", media.isPlaying ? "Pause" : "Play") {
            PictureInPicture.perform(media.isPlaying ? .pause : .play, on: id)
          }
          control("forward.end.fill", "Next Track", isEnabled: media.canNextTrack) {
            PictureInPicture.perform(.nextTrack, on: id)
          }
          control(MediaVolume.symbol(volume), "Adjust Tab Volume", isSelected: showsVolume) {
            Engine.shared.mediaVolume(id) { volume = $0 }
            withAnimation(Motion.row) { showsVolume.toggle() }
          }
        }
        .frame(height: 32)
        if showsVolume {
          VolumeSlider(value: volume) {
            volume = $0
            Engine.shared.setMediaVolume(id, $0)
          }
            .padding(.horizontal, 8)
            .frame(height: 33)
            .transition(.opacity)
        }
      }
      .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x050627)))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0x1E1F3D), lineWidth: 0.5))
      .padding(.horizontal, 8)
      .onHover { hovering in
        withAnimation(Motion.row) {
          isHovering = hovering
          if !hovering { showsVolume = false }
        }
      }
      .task(id: id) { Engine.shared.mediaVolume(id) { volume = $0 } }
    }
  }

  private func control(
    _ symbol: String, _ title: String, isEnabled: Bool = true, isSelected: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 14))
        .foregroundStyle(isEnabled ? Color(hex: 0xB0B1BB) : Color(hex: 0x3B3C55))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(MiniPlayerButtonStyle(isSelected: isSelected))
    .disabled(!isEnabled)
    .hoverTooltip(title, isEnabled: isEnabled)
    .frame(maxWidth: .infinity)
  }
}

// The control under the pointer, or whose slider is open, gets a rounded fill.
private struct MiniPlayerButtonStyle: ButtonStyle {
  var isSelected = false
  @State private var isHovering = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: 6).fill(.white.opacity((isHovering || isSelected) && isEnabled ? 0.08 : 0)))
      .onHover { isHovering = $0 }
  }
}

// The volume slider: a 3.5 pt track, lighter up to a 20 pt knob.
private struct VolumeSlider: View {
  let value: Double
  let set: (Double) -> Void

  var body: some View {
    GeometryReader { proxy in
      let travel = proxy.size.width - 20
      ZStack(alignment: .leading) {
        Capsule().fill(Color(hex: 0x282A4B)).frame(height: 3.5)
        Capsule().fill(Color(hex: 0x6C6C7A)).frame(width: 10 + travel * value, height: 3.5)
        Circle().fill(Color(hex: 0x9495A2)).frame(width: 20, height: 20).offset(x: travel * value)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { drag in
          set(min(max((drag.location.x - 10) / travel, 0), 1))
        })
    }
  }
}
