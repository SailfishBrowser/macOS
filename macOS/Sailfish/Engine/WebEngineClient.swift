import AppKit
import ComposableArchitecture
import EngineCore

struct WebPage: Equatable, Sendable {
  var url: URL?
  var title: String
  var favicon: NSImage?
  var isLoading: Bool
  var canGoBack: Bool
  var canGoForward: Bool
  var isAudible = false
  var isMuted = false
  var media: PageMedia?
  // The tab's pages, oldest first, and the one shown.
  var pages: [PageRecord]
  var shownPage: Int
}

struct Download: Equatable, Identifiable, Sendable {
  let id: String
  var url: URL
  var fileURL: URL?
  var receivedBytes: Int64
  var totalBytes: Int64
  var state: ECDownloadState
  var startTime: Date
  var profileID: UUID?
  // The name the file downloaded under, while Tidy Downloads has it renamed.
  var originalName: String?
}

enum WebEngineEvent: Equatable, Sendable {
  case updated(tab: UUID, page: WebPage)
  // A ⌘-click or middle-click asks for a background tab.
  case newWindowRequested(tab: UUID, url: URL, background: Bool)
  case windowRequested(tab: UUID, url: URL, incognito: Bool)
  case peekRequested(tab: UUID, url: URL, at: CGPoint)
  case splitRequested(tab: UUID, url: URL)
  case littleSailfishRequested(tab: UUID, url: URL)
  case closeRequested(tab: UUID)
  // A script's popup from a WebKit page, already a tab of its own, for the opener's space.
  case adoptRequested(tab: UUID, opener: UUID, url: URL)
  case activateRequested(tab: UUID)
  case found(tab: UUID, matches: Int, activeMatch: Int)
  // The page's zoom percent changed: a zoom step, or a navigation to a site with a remembered zoom.
  case zoomChanged(tab: UUID, percent: Int)
  case downloaded(Download)
  // A login typed into a WebKit page that the profile's store does not hold, for its window to offer saving.
  case loginSubmitted(tab: UUID, login: PendingLogin)
  // Protected video that failed in Chromium switched the tab to WebKit, for its window to offer Undo.
  case openedInWebKit(tab: UUID, site: String)
}

enum ZoomStep: Equatable, Sendable {
  case `in`, out, reset
}

@DependencyClient
struct WebEngineClient: Sendable {
  // Registers the tab's pages and makes the shown one from its saved history.
  var create: @Sendable (_ tab: UUID, _ profile: UUID, _ incognito: Bool, _ pages: [PageRecord], _ shown: Int) async -> Void
  var load: @Sendable (_ tab: UUID, _ url: URL) async -> Void
  // Reloads the shown page's URL in the other engine, as a page of its own.
  var switchEngine: @Sendable (_ tab: UUID, _ engine: PageEngineKind) async -> Void
  // Makes the Little Sailfish `id` a window holding its page `tab`, for the context's extensions.
  var littleWindow: @Sendable (_ id: UUID, _ profile: UUID, _ tab: UUID) async -> Void
  var goBack: @Sendable (_ tab: UUID) async -> Void
  var goForward: @Sendable (_ tab: UUID) async -> Void
  // Goes to a history entry of the tab, chosen in a back or forward menu.
  var goToEntry: @Sendable (_ tab: UUID, _ entry: HistoryEntry) async -> Void
  var reload: @Sendable (_ tab: UUID) async -> Void
  var stop: @Sendable (_ tab: UUID) async -> Void
  var setMuted: @Sendable (_ tab: UUID, _ muted: Bool) async -> Void
  var media: @Sendable (_ tab: UUID, _ command: MediaCommand) async -> Void
  var close: @Sendable (_ tab: UUID) async -> Void
  // Closes the tab's page and forgets its saved history.
  var discard: @Sendable (_ tab: UUID) async -> Void = { _ in }
  var closeIncognito: @Sendable (_ profile: UUID) async -> Void
  var deleteProfile: @Sendable (_ profile: UUID) async -> Void
  // Removes the WebKit stores of deleted profiles that were still in use when they were deleted.
  var removeDeletedStores: @Sendable () async -> Void = {}
  // Searches carry the time they were asked for; one older than the last the engine ran is dropped.
  var find: @Sendable (_ tab: UUID, _ string: String, _ forward: Bool, _ requested: ContinuousClock.Instant) async -> Void
  // Finds the string as typed: a changed string starts a new search, the same one keeps the active match.
  var findAsTyped: @Sendable (_ tab: UUID, _ string: String, _ requested: ContinuousClock.Instant) async -> Void
  var stopFinding: @Sendable (_ tab: UUID, _ requested: ContinuousClock.Instant) async -> Void
  var cancelDownload: @Sendable (_ id: Download.ID) async -> Void
  // Saves the login a toast offered to save, or forgets it when the toast goes unanswered.
  var saveLogin: @Sendable (_ id: PendingLogin.ID) async -> Void
  var dropLogin: @Sendable (_ id: PendingLogin.ID) async -> Void
  // Shows the Chromium page a switch to WebKit for protected video left, as Undo on its toast.
  var undoEngineSwitch: @Sendable (_ tab: UUID) async -> Void
  // Steps the page's zoom and returns its percent afterwards, nil without a page.
  var zoom: @Sendable (_ tab: UUID, _ step: ZoomStep) async -> Int?
  // Saves the live tabs' histories.
  var saveSessions: @Sendable () async -> Void = {}
  // Drops the saved histories of every page but these. It runs off the main actor, in the session writer's flush.
  var keepSessions: @Sendable (_ ids: Set<UUID>) -> Void = { _ in }
  // Gives a tab a copy of another tab's saved history.
  var copySession: @Sendable (_ from: UUID, _ to: UUID) async -> Void = { _, _ in }
  var events: @Sendable () -> AsyncStream<WebEngineEvent> = { .finished }
}

extension WebEngineClient: TestDependencyKey {
  static let testValue = Self()
}

extension DependencyValues {
  var webEngine: WebEngineClient {
    get { self[WebEngineClient.self] }
    set { self[WebEngineClient.self] = newValue }
  }
}
