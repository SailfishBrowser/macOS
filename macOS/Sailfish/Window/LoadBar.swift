import SwiftUI

// The load indicator, in the strip above the page card: a dash pulsing at the top centre while the page is
// awaited, then a track whose head moves right as the page loads, gone once it has.
struct LoadBar: View {
  let tab: Tab

  var body: some View {
    let progress = Engine.shared.loadProgress[tab.id] ?? 0
    let isShown = tab.isLoading && progress < 1
    ZStack {
      // Chrome holds the progress at 0.1 until the page's response arrives.
      if progress <= 0.1 {
        PulsingDash()
      } else {
        Capsule().fill(Theme.primaryText.opacity(0.26)).frame(width: 128, height: 4)
          .overlay(alignment: .leading) {
            Capsule().fill(Theme.primaryText.opacity(0.8)).frame(width: 95, height: 4)
              .offset(x: (progress - 0.1) / 0.9 * 33)
              .animation(Motion.row, value: progress)
          }
      }
    }
    .opacity(isShown ? 1 : 0)
    .animation(Motion.row, value: isShown)
    .allowsHitTesting(false)
  }
}

private struct PulsingDash: View {
  @State private var isLit = false

  var body: some View {
    Capsule().fill(Theme.primaryText).frame(width: 44, height: 4)
      .opacity(isLit ? 0.8 : 0)
      .onAppear { withAnimation(Motion.loadPulse) { isLit = true } }
  }
}
