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
  case activateRequested(tab: UUID)
  case found(tab: UUID, matches: Int, activeMatch: Int)
  // The page's zoom percent changed: a zoom step, or a navigation to a site with a remembered zoom.
  case zoomChanged(tab: UUID, percent: Int)
  case downloaded(Download)
}

enum ZoomStep: Equatable, Sendable {
  case `in`, out, reset
}

@DependencyClient
struct WebEngineClient: Sendable {
  var create: @Sendable (_ tab: UUID, _ profile: UUID, _ incognito: Bool) async -> Void
  var load: @Sendable (_ tab: UUID, _ url: URL) async -> Void
  var goBack: @Sendable (_ tab: UUID) async -> Void
  var goForward: @Sendable (_ tab: UUID) async -> Void
  // Goes to the history entry at `index` in the tab's history, chosen in a back or forward menu.
  var goToEntry: @Sendable (_ tab: UUID, _ index: Int) async -> Void
  var reload: @Sendable (_ tab: UUID) async -> Void
  var stop: @Sendable (_ tab: UUID) async -> Void
  var setMuted: @Sendable (_ tab: UUID, _ muted: Bool) async -> Void
  var media: @Sendable (_ tab: UUID, _ command: MediaCommand) async -> Void
  var close: @Sendable (_ tab: UUID) async -> Void
  // Closes the tab's page and forgets its saved history.
  var discard: @Sendable (_ tab: UUID) async -> Void = { _ in }
  var closeIncognito: @Sendable (_ profile: UUID) async -> Void
  var deleteProfile: @Sendable (_ profile: UUID) async -> Void
  // Searches carry the time they were asked for; one older than the last the engine ran is dropped.
  var find: @Sendable (_ tab: UUID, _ string: String, _ forward: Bool, _ requested: ContinuousClock.Instant) async -> Void
  // Finds the string as typed: a changed string starts a new search, the same one keeps the active match.
  var findAsTyped: @Sendable (_ tab: UUID, _ string: String, _ requested: ContinuousClock.Instant) async -> Void
  var stopFinding: @Sendable (_ tab: UUID, _ requested: ContinuousClock.Instant) async -> Void
  var cancelDownload: @Sendable (_ id: Download.ID) async -> Void
  // Steps the page's zoom and returns its percent afterwards, nil without a page.
  var zoom: @Sendable (_ tab: UUID, _ step: ZoomStep) async -> Int?
  // Saves the live tabs' histories.
  var saveSessions: @Sendable () async -> Void = {}
  // Drops the saved histories of every tab but these. It runs off the main actor, in the session writer's flush.
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
