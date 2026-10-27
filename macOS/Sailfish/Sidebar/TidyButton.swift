import SwiftUI

// Tidy beside Clear: a broom and "Tidy", white while hovered, with the "Organize Today Tabs" tooltip. After a
// click the broom sweeps.
struct TidyButton: View {
  let isTidying: Bool
  @Binding var isHovered: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        TimelineView(.animation(paused: !isTidying)) { context in
          Broom()
            .frame(width: 10, height: 11)
            .rotationEffect(.degrees(isTidying ? 18 * sin(context.date.timeIntervalSinceReferenceDate * 9) : 0), anchor: .top)
        }
        Text("Tidy").font(.system(size: 11, weight: .semibold))
      }
      .foregroundStyle(isHovered ? Theme.primaryText : Theme.secondaryText)
    }
    .buttonStyle(.plain)
    .disabled(isTidying)
    .onHover { isHovered = $0 }
    .hoverTooltip("Organize Today Tabs", isEnabled: !isTidying)
  }
}

// The divider's line, which ripples after Tidy.
struct TidyDividerLine: View {
  let isTidying: Bool
  let color: Color
  let lineWidth: CGFloat

  var body: some View {
    TimelineView(.animation(paused: !isTidying)) { context in
      Wave(phase: isTidying ? context.date.timeIntervalSinceReferenceDate * 8 : 0, amplitude: isTidying ? 1.5 : 0)
        .stroke(color, lineWidth: lineWidth)
    }
    .frame(height: 4)
  }
}

private struct Wave: Shape {
  let phase: Double
  let amplitude: CGFloat

  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.midY))
      for x in stride(from: rect.minX, through: rect.maxX, by: 1) {
        path.addLine(to: CGPoint(x: x, y: rect.midY + amplitude * sin(Double(x) / 3 - phase)))
      }
    }
  }
}

// A broom leaning right: its handle up to the top right, its bristles fanning out at the bottom left.
private struct Broom: View {
  var body: some View {
    Canvas { context, size in
      let w = size.width, h = size.height
      var handle = Path()
      handle.move(to: CGPoint(x: w * 0.95, y: 0))
      handle.addLine(to: CGPoint(x: w * 0.55, y: h * 0.5))
      context.stroke(handle, with: .foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
      var head = Path()
      head.move(to: CGPoint(x: w * 0.4, y: h * 0.42))
      head.addLine(to: CGPoint(x: w * 0.72, y: h * 0.62))
      head.addLine(to: CGPoint(x: w * 0.45, y: h))
      head.addLine(to: CGPoint(x: 0, y: h * 0.9))
      head.closeSubpath()
      context.fill(head, with: .foreground)
    }
  }
}
