import SwiftUI

// Above the footer once Sparkle has downloaded an update: styled as a selected tab row, with Restart to install it now.
struct UpdatePill: View {
  let version: String
  let theme: SpaceTheme
  let restart: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      // A narrow sidebar drops the icon so the label stays whole.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 16))
            .foregroundStyle(.white, Theme.accent)
          label
        }
        label
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: restart) {
        Text("Restart")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 10)
          .frame(height: 24)
          .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
      }
      .buttonStyle(.plain)
    }
    .padding(.leading, 10)
    .padding(.trailing, 6)
    .frame(height: 36)
    .background {
      RoundedRectangle(cornerRadius: 12)
        .fill(Theme.rowSelection(theme))
        .shadow(color: Theme.rowShadow, radius: 2, y: 1.5)
    }
    .hoverTooltip("Sailfish \(version)")
    .padding(.horizontal, 8)
    .padding(.bottom, 4)
  }

  private var label: some View {
    Text("Update ready")
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(Theme.rowText)
      .lineLimit(1)
      .minimumScaleFactor(0.9)
  }
}
