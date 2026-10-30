import Foundation

// The spaces of the regular windows, with their pinned pages and open tabs, as the phone shows them.
struct MacTabs: Equatable, Sendable {
  struct Page: Equatable, Sendable {
    let url: URL
    let title: String
    let iconPage: URL
  }
  struct Entry: Equatable, Sendable {
    let id: Space.ID
    let profileID: Profile.ID
    let name: String
    let pinned: [Page]
    let tabs: [Page]
  }
  var spaces: [Entry]
  var current: Space.ID?
}

extension AppFeature.State {
  var macTabs: MacTabs? {
    guard isLoaded else { return nil }
    let regular = windows.filter { !$0.isIncognito }
    return MacTabs(
      spaces: regular.flatMap(\.spaces.spaces).map { space in
        MacTabs.Entry(
          id: space.id,
          profileID: space.profileID,
          name: space.name,
          pinned: space.tree(.pinned).compactMap { row in
            guard case let .tab(tab) = row else { return nil }
            return MacTabs.Page(tab.pinnedURL ?? tab.url, title: tab.displayTitle, iconPage: tab.iconPage)
          },
          tabs: space.orderedTabs(in: .unpinned).compactMap {
            MacTabs.Page($0.url, title: $0.displayTitle, iconPage: $0.iconPage)
          }
        )
      },
      current: (focusedWindowID.flatMap { regular[id: $0] } ?? regular.last)?.spaces.selectedID
    )
  }
}

extension MacTabs.Page {
  // Only pages the phone can open, without the URL's user and password, and with the title cut to 300 characters.
  init?(_ url: URL, title: String, iconPage: URL) {
    guard ["http", "https"].contains(url.scheme), url.absoluteString.utf8.count <= 4096,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    components.user = nil
    components.password = nil
    guard let clean = components.url else { return nil }
    self.init(url: clean, title: String(title.prefix(300)), iconPage: iconPage)
  }
}
