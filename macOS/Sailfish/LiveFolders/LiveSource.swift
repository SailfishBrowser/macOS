import ComposableArchitecture
import Foundation

// A live folder's source: it reads one kind of URL and answers which links belong in the folder right now.
protocol LiveSource: Sendable {
  // The source for a URL it reads, else nil.
  init?(url: URL)
  // The folder's name before its first fill.
  var name: String { get }
  func fetch() async throws -> LiveFeed
}

struct LiveFeed: Equatable, Sendable {
  // The source's own title, such as a feed's, which names a folder still called by its URL.
  var title: String?
  var links: [LiveLink]
}

struct LiveLink: Equatable, Sendable {
  let url: URL
  let title: String
}

enum LiveSources {
  // Tried in order; a feed reads any web address, so it goes last.
  static let all: [any LiveSource.Type] = [GitHubPulls.self, Feed.self]
  // How long a live folder waits between refreshes.
  static let interval: TimeInterval = 15 * 60

  static func source(for url: URL) -> (any LiveSource)? {
    all.lazy.compactMap { $0.init(url: url) }.first
  }

  // A URL typed without a scheme is taken as https.
  static func url(typed text: String) -> URL? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(string: text.contains("://") ? text : "https://" + text).flatMap { source(for: $0) == nil ? nil : $0 }
  }

  // The body of a successful response.
  static func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = response as! HTTPURLResponse
    guard (200..<300).contains(http.statusCode) else { throw LiveSourceError.status(http.statusCode) }
    return (data, http)
  }
}

enum LiveSourceError: LocalizedError {
  case status(Int)
  case notAFeed
  case unsupported
  case rateLimited(until: Date)

  var errorDescription: String? {
    switch self {
    case let .status(code): "HTTP \(code)"
    case .notAFeed: "No RSS or Atom feed at this address"
    case .unsupported: "Unsupported address"
    case let .rateLimited(until): "GitHub rate limit until \(until.formatted(date: .omitted, time: .shortened))"
    }
  }
}

// What a live folder keeps about its source. Only the URL and the last fill are saved; at launch a folder refreshes
// at once.
struct LiveFolderSource: Codable, Equatable {
  var url: URL
  // The last refresh that filled the folder; items arriving after one are unread.
  var refreshedAt: Date?
  var refreshAfter = Date.distantPast
  // Why the last refresh failed; the folder keeps its tabs as they were.
  var failure: String?

  enum CodingKeys: String, CodingKey {
    case url, refreshedAt
  }
}

private enum FetchLiveFeedKey: DependencyKey {
  static let liveValue: @Sendable (URL) async throws -> LiveFeed = { url in
    guard let source = LiveSources.source(for: url) else { throw LiveSourceError.unsupported }
    return try await source.fetch()
  }
  static let testValue: @Sendable (URL) async throws -> LiveFeed = unimplemented("fetchLiveFeed")
}

extension DependencyValues {
  var fetchLiveFeed: @Sendable (URL) async throws -> LiveFeed {
    get { self[FetchLiveFeedKey.self] }
    set { self[FetchLiveFeedKey.self] = newValue }
  }
}

extension TabsFeature.State {
  // Whether tabs and folders can be put in a container: a live folder's tabs come from its source alone.
  func takesRows(_ container: Placement) -> Bool {
    guard case let .folder(id) = container else { return true }
    return folders[id: id]?.source == nil
  }

  // Lays the source's links out in a live folder, in the source's order. A new link arrives unloaded; one already
  // pinned elsewhere in the space, as an item dragged out of the folder, is left there. Tabs for links the source
  // dropped are taken out before this.
  mutating func fill(_ id: Folder.ID, with links: [LiveLink], isUnread: Bool, now: Date, uuid: () -> UUID) {
    var items = Dictionary(tabs(in: .folder(id)).map { ($0.pinnedURL ?? $0.url, $0.id) }, uniquingKeysWith: { first, _ in first })
    let elsewhere = Set(tabs.filter { $0.placement != .folder(id) }.compactMap(\.pinnedURL))
    var arrived: Set<Tab.ID> = []
    for link in links where !elsewhere.contains(link.url) {
      if let item = items[link.url] {
        if ownTabs[id: item]?.isLive == false { ownTabs[id: item]?.title = link.title }
      } else {
        var tab = Tab(
          id: uuid(), url: link.url, title: link.title, placement: .folder(id), pinnedURL: link.url, createdAt: now,
          lastActiveAt: now)
        tab.isUnread = isUnread
        ownTabs.append(tab)
        items[link.url] = tab.id
        arrived.insert(tab.id)
      }
      place(items[link.url]!, before: nil)
    }
    arrivals = arrived
  }
}
