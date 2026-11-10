import SwiftUI

// Holding Shift on a link previews its page, as Arc's 5-second previews did: a card by the pointer fills with a few
// labelled lines that Apple's on-device model writes about the page. Releasing Shift or leaving the link closes it.
// Typing with Shift held previews nothing until Shift is pressed again. The card takes no clicks, so the link
// under it still opens.
@available(macOS 26, *)
struct LinkPreviewOverlay: View {
  let tab: Tab.ID
  let accent: Color
  @State private var isShiftDown = false
  @State private var monitor: Any?
  @State private var frame = CGRect.zero
  @State private var preview: Preview?
  @State private var cardSize = CGSize.zero

  private struct Preview: Equatable {
    var url: URL
    // The pointer when the card opened, in this view's space.
    var anchor: CGPoint
  }

  private struct Trigger: Equatable {
    var link: URL?
    var isShiftDown: Bool
  }

  var body: some View {
    let link = Engine.shared.hoveredLinks[tab]
    ZStack(alignment: .topLeading) {
      Color.clear
      if let preview {
        LinkPreviewCard(url: preview.url, accent: accent)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
          .offset(origin(for: preview.anchor))
          .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .allowsHitTesting(false)
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    .onChange(of: Trigger(link: link, isShiftDown: isShiftDown)) { _, trigger in
      guard let url = trigger.link, trigger.isShiftDown, url.scheme == "https" || url.scheme == "http",
        LinkSummaries.isAvailable
      else {
        withAnimation(.easeOut(duration: 0.12)) { preview = nil }
        return
      }
      guard preview?.url != url, let anchor = pointer() else { return }
      withAnimation(.easeOut(duration: 0.15)) { preview = Preview(url: url, anchor: anchor) }
    }
    .onAppear {
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
        // Shift alone counts; a key typed while it is down is typing, not a preview.
        isShiftDown =
          event.type == .flagsChanged && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
        return event
      }
    }
    .onDisappear {
      monitor.map(NSEvent.removeMonitor)
      monitor = nil
    }
  }

  // Below and right of the pointer, or above it where the card would pass the page's bottom, 8 pt inside the page.
  private func origin(for anchor: CGPoint) -> CGSize {
    let inset: CGFloat = 8
    let x = min(max(anchor.x + 14, inset), max(frame.width - cardSize.width - inset, inset))
    let below = anchor.y + 22
    let y = below + cardSize.height <= frame.height - inset ? below : max(anchor.y - 12 - cardSize.height, inset)
    return CGSize(width: x, height: y)
  }

  // The pointer in this view's space, from its window's content, whose coordinates SwiftUI's global space uses.
  private func pointer() -> CGPoint? {
    let location = NSEvent.mouseLocation
    guard
      let window = NSApp.window(
        withWindowNumber: NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0)),
      let content = window.contentView
    else { return nil }
    let point = window.convertPoint(fromScreen: location)
    let local = CGPoint(x: point.x - frame.minX, y: content.frame.height - point.y - frame.minY)
    guard local.x >= 0, local.y >= 0, local.x <= frame.width, local.y <= frame.height else { return nil }
    return local
  }
}

// The preview: the link's site, then the model's lines as they are written, on the link bubble's dark fill.
@available(macOS 26, *)
private struct LinkPreviewCard: View {
  let url: URL
  let accent: Color
  @State private var state = LinkSummaries.State.reading

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "sparkles")
        Text(url.host(percentEncoded: false) ?? url.statusText).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
        if case .reading = state { ProgressView().controlSize(.mini) }
        if case .writing = state { ProgressView().controlSize(.mini) }
      }
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.white.opacity(0.55))
      content
    }
    .padding(14)
    .frame(width: 340, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.92))
        .overlay(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.25)))
    )
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    .task(id: url) {
      state = .reading
      for await next in LinkSummaries.shared.summary(of: url) {
        withAnimation(.easeOut(duration: 0.15)) { state = next }
      }
    }
  }

  @ViewBuilder private var content: some View {
    switch state {
    case .reading:
      Text("Reading the page…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
    case let .writing(points), let .done(points):
      VStack(alignment: .leading, spacing: 8) {
        ForEach(points.indices, id: \.self) { index in
          let point = points[index]
          Group {
            if point.label.isEmpty {
              Text(point.text)
            } else {
              Text("\(Text(point.label + ":").fontWeight(.semibold)) \(point.text)")
            }
          }
          .font(.system(size: 13))
          .foregroundStyle(.white.opacity(0.9))
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    case let .failed(message):
      Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
    }
  }
}
