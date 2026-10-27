import SwiftUI

extension URL {
  // The link as the status bubble shows it: no scheme, and no slash after a bare host.
  var statusText: String {
    var text = absoluteString.removingPercentEncoding ?? absoluteString
    if let scheme, text.hasPrefix(scheme + "://") {
      text.removeFirst(scheme.count + 3)
    }
    if path() == "/", query() == nil, fragment() == nil, text.hasSuffix("/") {
      text.removeLast()
    }
    return text
  }
}

// The hovered link's URL at the page's bottom left. Once the pointer has rested on the link for 1.5 s
// the bubble shows the full URL, and moves to the bottom right if the pointer is over it.
struct LinkBubble: View {
  let url: URL
  let accent: Color
  @State private var isExpanded = false
  @State private var avoidsPointer = false

  var body: some View {
    Text(isExpanded ? url.absoluteString.removingPercentEncoding ?? url.absoluteString : url.statusText)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.white.opacity(0.85))
      .lineLimit(isExpanded ? 4 : 1)
      .truncationMode(.middle)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .frame(minHeight: 24)
      .background(RoundedRectangle(cornerRadius: 12).fill(.black).overlay(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.3))))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
        if isExpanded, !avoidsPointer, Self.pointerIsOver(frame) {
          avoidsPointer = true
        }
      }
      // 10 pt from the card's leading and bottom edges.
      .padding(10)
      .frame(maxWidth: .infinity, alignment: avoidsPointer ? .trailing : .leading)
      .allowsHitTesting(false)
      .task(id: url) {
        isExpanded = false
        avoidsPointer = false
        guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
        isExpanded = true
      }
  }

  // Whether the pointer is over a frame in its window's content, whose coordinates SwiftUI's global space uses.
  private static func pointerIsOver(_ frame: CGRect) -> Bool {
    let location = NSEvent.mouseLocation
    guard let window = NSApp.window(withWindowNumber: NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0)),
      let content = window.contentView
    else { return false }
    let point = window.convertPoint(fromScreen: location)
    return frame.contains(CGPoint(x: point.x, y: content.frame.height - point.y))
  }
}
