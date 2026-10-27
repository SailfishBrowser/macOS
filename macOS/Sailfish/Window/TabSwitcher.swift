import ComposableArchitecture
import SwiftUI

// The tab switcher: while ⌃ stays held after ⌃Tab, the recent tabs show as cards, each with its page as it last
// looked, the one ⌃Tab is on filled with its space's theme. Releasing ⌃ shows that tab; ⌃W closes it.
// Geometry: a 16 pt padded panel of 181 x 158 pt cards with a 161 x 108 pt thumbnail.
struct TabSwitcher: View {
  let cycle: WindowFeature.RecentCycle
  let spaces: IdentifiedArrayOf<Space>
  private var thumbnails: [Tab.ID: NSImage] { Engine.shared.thumbnails }

  static let thumbnailSize = CGSize(width: 161, height: 108)

  var body: some View {
    HStack(spacing: 0) {
      ForEach(cycle.tabs, id: \.self) { id in
        if let space = spaces.first(where: { $0.tabs[id: id] != nil }), let tab = space.tabs[id: id] {
          card(tab, in: space, isCurrent: id == cycle.tab)
        }
      }
    }
    .padding(16)
    .background(Theme.switcher, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.switcherRim))
    .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
  }

  private func card(_ tab: Tab, in space: Space, isCurrent: Bool) -> some View {
    VStack(spacing: 10) {
      thumbnail(tab, in: space)
      HStack(spacing: 6) {
        TabIconView(tab: tab, space: space)
        Text(tab.displayTitle).font(.system(size: 13, weight: .bold)).lineLimit(1).foregroundStyle(Theme.primaryText)
      }
      .frame(height: 20)
    }
    .padding(10)
    .frame(width: 181, height: 158)
    .background {
      if isCurrent {
        LinearGradient(theme: space.theme).opacity(0.7).clipShape(RoundedRectangle(cornerRadius: 10))
      }
    }
  }

  @ViewBuilder private func thumbnail(_ tab: Tab, in space: Space) -> some View {
    Group {
      if let image = thumbnails[tab.id] {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
      } else {
        // A page not seen since the window opened: its favicon on its space's theme.
        LinearGradient(theme: space.theme).opacity(0.5)
          .overlay { TabIconView(tab: tab, space: space).scaleEffect(2) }
      }
    }
    .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.switcherRim.opacity(0.6)))
  }
}

// A tab's icon or favicon, as the sidebar shows it.
private struct TabIconView: View {
  let tab: Tab
  let space: Space

  var body: some View {
    if let icon = tab.icon {
      SpaceIcon(icon: icon, emojiSize: 15)
    } else {
      TabFavicon(tab: tab, space: space)
    }
  }
}

extension NSImage {
  // A copy at a width, keeping the proportions; a smaller image is kept as it is.
  func scaled(toWidth width: CGFloat) -> NSImage {
    guard size.width > width, size.width > 0 else { return self }
    let target = NSSize(width: width, height: size.height * width / size.width)
    let image = NSImage(size: target)
    image.lockFocus()
    draw(in: NSRect(origin: .zero, size: target), from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
    image.unlockFocus()
    return image
  }
}
