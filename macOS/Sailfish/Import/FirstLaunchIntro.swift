import AppKit
import SwiftUI

// The first launch's opening, over the window only: the app icon fades and grows in on black, holds, flies to where the
// onboarding dialog's icon sits, and the dialog comes down around it; then the black fades to the window. The sheet is
// a window of its own above this one, so it comes only once the icon has landed, or it would hide the flight.
struct FirstLaunchIntro: View {
  let land: () -> Void
  let end: () -> Void
  @State private var phase = Phase.dark

  private enum Phase {
    case dark, shown, landed, gone
  }

  var body: some View {
    GeometryReader { proxy in
      let isLanded = phase == .landed || phase == .gone
      let size: CGFloat = isLanded ? 48 : 128
      ZStack {
        Color.black.opacity(phase == .gone ? 0 : 1)
        Image(nsImage: NSApp.applicationIconImage).resizable()
          .frame(width: size, height: size)
          .scaleEffect(phase == .dark ? 0.85 : 1)
          .opacity(phase == .dark ? 0 : 1)
          .position(isLanded ? Self.corner(in: proxy.size) : CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2))
      }
    }
    .ignoresSafeArea()
    .allowsHitTesting(phase != .gone)
    .task {
      withAnimation(Motion.intro) { phase = .shown }
      try? await Task.sleep(for: .seconds(0.9))
      withAnimation(Motion.layout) { phase = .landed }
      try? await Task.sleep(for: .seconds(0.3))
      land()
      try? await Task.sleep(for: .seconds(0.3))
      withAnimation(Motion.layout) { phase = .gone }
      try? await Task.sleep(for: .seconds(0.3))
      end()
    }
  }

  // The center of the dialog's 48 pt icon: the sheet hangs centered, its top this far below the window's (macOS 15).
  private static func corner(in window: CGSize) -> CGPoint {
    let inset = ImportView.padding + 24
    return CGPoint(x: (window.width - ImportView.size.width) / 2 + inset, y: sheetTop + inset)
  }

  private static let sheetTop: CGFloat = 33
}
