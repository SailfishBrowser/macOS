import SwiftUI

// The zoom indicator: the page's zoom percent in a pill at the page card's top-right corner after ⌘+, ⌘- or
// ⌘0. It fades in over about 165 ms, stays 5 s from the last step and fades out in about 75 ms (WindowFeature
// drives the timing). A 42 pt pill with 12 pt side padding, radius 10, the space's color with 17 pt semibold
// text.
struct ZoomIndicator: View {
  let percent: Int
  let theme: SpaceTheme
  let isIncognito: Bool

  static let duration: Duration = .seconds(5)

  var body: some View {
    Text("\(percent)%")
      .font(.system(size: 17, weight: .semibold))
      .foregroundStyle(isIncognito || !Theme.isLight(theme) ? Color.white : Color(hex: 0x18161C))
      .padding(.horizontal, 12)
      .frame(height: 42)
      .background(fill, in: RoundedRectangle(cornerRadius: 10))
      .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
      .transition(.opacity)
  }

  private var fill: Color {
    isIncognito ? Theme.incognitoPill : Color(hex: theme.gradient[0])
  }
}
