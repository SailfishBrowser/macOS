import ComposableArchitecture
import SwiftUI

extension WindowFeature {
  // Leaving a tab that plays, video or sound, shows its controls at the foot of the sidebar. Showing the tab again
  // hides them and brings back its video from Picture in Picture.
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
    if let shown, shown != selected, media(shown)?.isPlaying == true {
      state.miniPlayer = shown
    }
    return .merge(effects)
  }
}

// The mini player, on the favorites tile's fill and radius: a tab's favicon (back to the tab), previous, play or pause,
// next and the tab's volume. Hovering it shows the tab's title and a close button above; the
// speaker opens a volume slider below until the pointer leaves. It goes once the page has no media.
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
            Text(tab.displayTitle).font(.system(size: 13)).foregroundStyle(Theme.rowText).lineLimit(1)
            Spacer(minLength: 8)
            control("xmark", "Close Mini Player") { store.send(.closeMiniPlayer) }
              .frame(width: 26)
          }
          .padding(.leading, 14)
          .padding(.trailing, 9)
          .frame(height: 33)
          .transition(.opacity)
        }
        HStack(spacing: 0) {
          Button { store.send(.openFromLibrary(space.id, tab: id)) } label: {
            TabFavicon(tab: tab, profileID: space.profileID, isIncognito: space.isIncognito).frame(width: 24, height: 24).contentShape(Rectangle())
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
      .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12))
      .padding(.horizontal, 8)
      .hoverRegion { hovering in
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
        .font(.system(size: 15))
        .foregroundStyle(Theme.icon)
        .opacity(isEnabled ? 1 : 0.42)
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
      .background((isHovering || isSelected) && isEnabled ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
      .hoverRegion { isHovering = $0 }
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
        Capsule().fill(Theme.divider).frame(height: 3.5)
        Capsule().fill(Theme.secondaryText).frame(width: 10 + travel * value, height: 3.5)
        Circle().fill(Theme.icon).frame(width: 20, height: 20).offset(x: travel * value)
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
