import AppKit
@preconcurrency import EngineCore
import WebKit

// A WebKit page's visit to one URL, written to Chromium's history once its title settles, and the icon written for
// it.
struct WebKitVisit {
  let url: URL
  let profile: UUID
  let committed: ContinuousClock.Instant
  var title: String
  var isRecorded = false
  var icon: URL?
  var write: Task<Void, Never>?
}

// WebKit pages' history and favicons go into the profile's Chromium history, so history, autocomplete and the saved
// favicons of unloaded tabs include them.
extension Engine {
  // Chromium adds a visit at commit and its title as the page sets it, for up to 5 seconds; one call does both here,
  // so the visit waits until the title has not changed for 1.5 seconds, and no longer than those 5 seconds. A new URL
  // in the page, by a load or by the page's own history, is a new visit. Incognito pages record nothing.
  func recordVisit(_ tab: UUID, _ page: WebKitPage) {
    guard !incognitoTabs.contains(tab), let profile = tabProfiles[tab], let url = page.committedURL else { return }
    let title = page.webView.title ?? ""
    guard let visit = page.visit, visit.url == url else {
      page.visit = WebKitVisit(url: url, profile: profile, committed: .now, title: title)
      return scheduleVisit(page)
    }
    if visit.isRecorded {
      return writeFavicon(page)
    }
    guard visit.title != title else { return }
    page.visit?.title = title
    scheduleVisit(page)
  }

  // A visit is written even when its page closes or moves on first, as Chromium's is at commit.
  private func scheduleVisit(_ page: WebKitPage) {
    guard let visit = page.visit else { return }
    visit.write?.cancel()
    let delay: Duration = min(.seconds(1.5), max(.zero, .seconds(5) - visit.committed.duration(to: .now)))
    page.visit?.write = Task { [weak self, weak page] in
      guard (try? await Task.sleep(for: delay)) != nil, let self, let context = self.contexts[visit.profile] else { return }
      context.addVisit(to: visit.url, title: visit.title)
      guard let page, page.visit?.url == visit.url else { return }
      page.visit?.isRecorded = true
      self.writeFavicon(page)
    }
  }

  // The page's icon, once its visit is written, the page has loaded and the icon it lists has been fetched, so a page
  // never gets the icon of the one before it.
  private func writeFavicon(_ page: WebKitPage) {
    guard let visit = page.visit, visit.isRecorded, !page.webView.isLoading, let icon = page.faviconURL,
      icon == page.iconURL, icon != visit.icon, let image = page.favicon, let context = contexts[visit.profile]
    else { return }
    context.setFavicon(image, iconURL: icon, forPageURL: visit.url)
    page.visit?.icon = icon
  }
}
