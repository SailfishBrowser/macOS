import ComposableArchitecture
import SwiftUI

// Peek: the page in a card over the dimmed tab, with close, expand and split buttons beside it.
// Its frame, offset and dimming are linear in progress, so SwiftUI animates them between the link and full size.
struct PeekOverlay: View {
  let store: StoreOf<WindowFeature>
  let peek: WindowFeature.Peek
  let progress: Double
  let showsPage: Bool

  var body: some View {
    GeometryReader { proxy in
      // Shot 66: the card spans 344-1345 of a 1240.5 pt page card from 219.5, 2 pt below its top and above its bottom.
      let full = CGRect(
        x: proxy.size.width * 0.1, y: 2, width: proxy.size.width * 0.807, height: proxy.size.height - 4)
      let start = CGRect(x: peek.origin.x - 20, y: peek.origin.y - 10, width: 40, height: 20)
      let card = CGRect(
        x: start.minX + (full.minX - start.minX) * progress, y: start.minY + (full.minY - start.minY) * progress,
        width: start.width + (full.width - start.width) * progress,
        height: start.height + (full.height - start.height) * progress)
      ZStack(alignment: .topLeading) {
        Color.black.opacity(0.55 * progress)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .onTapGesture { store.send(.closePeek) }
        ZStack {
          RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x232323))
          if showsPage, let view = Engine.shared.view(peek.tab.id) {
            WebView(view: view, roundsTop: true, cornerRadius: 10)
          }
        }
        .frame(width: card.width, height: card.height)
        .shadow(color: .black.opacity(0.4), radius: 20, y: 6)
        .offset(x: card.minX, y: card.minY)
        .overlay(alignment: .bottomLeading) {
          if let link = Engine.shared.hoveredLinks[peek.tab.id] {
            LinkBubble(url: link, accent: Theme.accent).offset(x: card.minX, y: card.maxY - proxy.size.height)
          }
        }
        // Shot 66: 34 pt buttons 43 pt apart, 13 pt right of the card.
        VStack(spacing: 9) {
          PeekButton(systemName: "xmark", help: "Close") { store.send(.closePeek) }
          PeekButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Open as Tab") {
            store.send(.expandPeek(split: false))
          }
          PeekButton(systemName: "rectangle.split.2x1", help: "Open in Split View") {
            store.send(.expandPeek(split: true))
          }
        }
        .opacity(progress)
        .offset(x: full.maxX + 13, y: full.minY + 8)
      }
    }
  }
}

private struct PeekButton: View {
  let systemName: String
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 34, height: 34)
        .background(Color(hex: 0x111216), in: Circle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}
