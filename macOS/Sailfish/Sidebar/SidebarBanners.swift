import ComposableArchitecture
import SwiftUI

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // The pinned-section hint, shown in a space with nothing pinned until it is closed.
  static var showsPinnedHint: Self { Self[.appStorage("showsPinnedHint"), default: true] }
}

extension SharedKey where Self == AppStorageKey<AutoArchiveBanner>.Default {
  // The Auto Archive banner: unseen until the first idle archive, shown from then until it is closed.
  static var autoArchiveBanner: Self { Self[.appStorage("autoArchiveBanner"), default: .unseen] }
}

enum AutoArchiveBanner: String, Codable {
  case unseen
  case shown
  case dismissed
}

// The hint in an empty pinned section, in the dashed card of the Favorites hint.
struct PinnedHint: View {
  let theme: SpaceTheme
  let dismiss: () -> Void

  var body: some View {
    SidebarHintCard(dismiss: dismiss) {
      Image(systemName: "pin.circle.fill")
        .symbolRenderingMode(.palette)
        .foregroundStyle(Theme.isLight(theme) ? .white : Theme.menu, Theme.isLight(theme) ? Theme.accent(theme) : .white)
        .font(.system(size: 18))
        .shadow(color: .white.opacity(Theme.isLight(theme) ? 0 : 0.35), radius: 4)
        .padding(.bottom, 2)
      Text("Pin tabs to save for later").font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.primaryText)
      Text("Like a bookmarks bar, your Pinned Tabs keep the things you need within reach").font(.system(size: 12))
        .foregroundStyle(Theme.favoritesHintText)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
    }
  }
}

// The Auto Archive banner above the footer, the first time idle tabs are archived: the threshold and where it
// is set.
struct AutoArchiveBannerView: View {
  let after: TimeInterval
  let dismiss: () -> Void

  var body: some View {
    SidebarHintCard(dismiss: dismiss) {
      Image(systemName: "archivebox.fill").font(.system(size: 18)).foregroundStyle(Theme.primaryText).padding(.bottom, 2)
      Text("Auto Archive").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
      Text("Tabs you haven’t used in the past \(Self.threshold(after))\nare archived. You can adjust this in Settings.")
        .font(.system(size: 12))
        .foregroundStyle(Theme.favoritesHintText)
        .multilineTextAlignment(.center)
      // The Profiles pane, where "Archive tabs after" is set.
      Button("Settings") {
        let item = NSMenuItem()
        item.tag = SettingsPane.profiles.rawValue
        NSApp.sendAction(#selector(Shell.showSettings(_:)), to: nil, from: item)
      }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.primaryText)
        .padding(.top, 4)
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 4)
  }

  // The thresholds: 1, 6, 12 or 24 hours, 7 or 30 days.
  private static func threshold(_ interval: TimeInterval) -> String {
    let hours = Int(interval / 3600)
    if hours < 48 { return hours == 1 ? "1 hour" : "\(hours) hours" }
    return "\(hours / 24) days"
  }
}

// The dashed card the sidebar's hints share, with an × that closes it.
private struct SidebarHintCard<Content: View>: View {
  let dismiss: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 3) { content }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
      // Sidebar tiles and rows: 12.05pt and 12.04pt continuous.
      .background(Theme.favoritesHintFill, in: RoundedRectangle(cornerRadius: 12))
      .background(
        RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.favoritesBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      )
      .overlay(alignment: .topTrailing) {
        Button(action: dismiss) {
          Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.primaryText)
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .padding(5)
      }
  }
}
