import ComposableArchitecture
import SwiftUI

// The "Space swipe" card of the Advanced pane: the commit rule's two numbers, for tuning on a real trackpad.
struct SpaceSwipeTuning: View {
  @Shared(.swipeCommitSpeed) private var commitSpeed
  @Shared(.swipeCommitDistance) private var commitDistance

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Space swipe").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
      VStack(spacing: 0) {
        row("Commit speed", symbol: "hare.fill", color: .orange, value: $commitSpeed, range: 20...600, step: 10, unit: "pt/s")
        Divider().padding(.horizontal, 10)
        row("Commit distance", symbol: "ruler.fill", color: .teal, value: $commitDistance, range: 3...50, step: 1, unit: "%")
      }
      .settingsCard()
    }
  }

  private func row(
    _ title: String, symbol: String, color: Color, value: Shared<Double>, range: ClosedRange<Double>, step: Double, unit: String
  ) -> some View {
    HStack(spacing: 10) {
      AdvancedIcon(symbol: symbol, color: color)
      Text(title).font(.system(size: 13))
      Spacer()
      Slider(value: Binding(value), in: range, step: step).frame(width: 160).controlSize(.small)
      Text("\(Int(value.wrappedValue)) \(unit)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        .frame(width: 56, alignment: .trailing)
    }
    .padding(.horizontal, 10)
    .frame(height: 40)
  }
}
