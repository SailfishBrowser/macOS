import AppKit
import SwiftUI

// The Library gift card: the app icon, a big title and a ticket with a link to pass along and a COPY LINK button.
struct ShareSailfish: View {
  static let link = URL(string: "https://sail.fish")!
  static let message = "Here’s a link to download Sailfish, the browser I was telling you about!"
  private static let green = Color(hex: 0x47C78E)

  let dismiss: () -> Void
  @State private var isCopied = false

  var body: some View {
    VStack(spacing: 0) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
      Text("Share Sailfish")
        .font(.system(size: 44, weight: .black, design: .rounded))
        .minimumScaleFactor(0.8)
        .foregroundStyle(.white)
        .frame(height: 48)
        .padding(.top, 14)
      ticket.padding(.top, 24)
    }
    .padding(.vertical, 64)
    .frame(width: 450)
    .background(Color(hex: 0x171C2F), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1)))
    .overlay(alignment: .topTrailing) {
      Button(action: dismiss) {
        Image(systemName: "xmark").font(.system(size: 15, weight: .medium)).foregroundStyle(Color(hex: 0xB8BAC3))
          .frame(width: 28, height: 28).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .help("Close")
      .padding(11)
    }
    .task(id: isCopied) {
      guard isCopied, (try? await Task.sleep(for: .seconds(2))) != nil else { return }
      isCopied = false
    }
  }

  private var ticket: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 17) {
        Text(Self.message).fixedSize(horizontal: false, vertical: true)
        Text(Self.link.absoluteString).textSelection(.enabled)
      }
      .font(.system(size: 17))
      .foregroundStyle(.white)
      .padding(.horizontal, 8.5)
      .padding(.top, 31)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity, minHeight: 133, alignment: .topLeading)
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.link.absoluteString, forType: .string)
        isCopied = true
      } label: {
        Text(isCopied ? "COPIED" : "COPY LINK").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
          .frame(maxWidth: .infinity, minHeight: 29)
          .background(Self.green, in: RoundedRectangle(cornerRadius: 6))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding([.horizontal, .top], 8.5)
      .padding(.bottom, 14)
      .background(Color(hex: 0x76E2B1))
      .overlay(alignment: .top) {
        Line().stroke(Self.green, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).frame(height: 1)
      }
    }
    .background(Color(hex: 0x1E303D))
    .clipShape(Ticket())
    .overlay(Ticket().stroke(Self.green, lineWidth: 1.5))
    .frame(width: 280)
  }
}

// A rectangle with zigzag top and bottom edges, like a torn ticket.
private struct Ticket: Shape {
  func path(in rect: CGRect) -> Path {
    let tooth: CGFloat = 8
    let depth: CGFloat = 3.5
    let steps = Int((rect.width / tooth).rounded())
    let step = rect.width / CGFloat(steps)
    var path = Path()
    path.move(to: CGPoint(x: 0, y: depth))
    for i in 1...steps {
      path.addLine(to: CGPoint(x: CGFloat(i) * step, y: i.isMultiple(of: 2) ? depth : 0))
    }
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
    for i in stride(from: steps - 1, through: 0, by: -1) {
      path.addLine(to: CGPoint(x: CGFloat(i) * step, y: i.isMultiple(of: 2) ? rect.maxY - depth : rect.maxY))
    }
    path.closeSubpath()
    return path
  }
}

private struct Line: Shape {
  func path(in rect: CGRect) -> Path {
    Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
  }
}
