import Foundation

// An RSS or Atom feed. A site's address leads to the feed its page links as alternate.
struct Feed: LiveSource {
  let url: URL

  init?(url: URL) {
    guard ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil else { return nil }
    self.url = url
  }

  var name: String { url.host()! }

  func fetch() async throws -> LiveFeed {
    let (data, _) = try await LiveSources.get(Self.request(url))
    if let feed = FeedParser.parse(data, base: url) { return feed }
    guard let alternate = Self.alternate(in: data, base: url) else { throw LiveSourceError.notAFeed }
    let (feedData, _) = try await LiveSources.get(Self.request(alternate))
    guard let feed = FeedParser.parse(feedData, base: alternate) else { throw LiveSourceError.notAFeed }
    return feed
  }

  // Every refresh reads the feed as it is now.
  private static func request(_ url: URL) -> URLRequest {
    URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
  }

  // The first <link> on the page typed as an RSS or Atom feed.
  private static func alternate(in data: Data, base: URL) -> URL? {
    let html = String(decoding: data, as: UTF8.self)
    for tag in html.matches(of: /<link\b[^>]*>/.ignoresCase()) {
      let tag = String(tag.output)
      guard tag.contains(/application\/(rss|atom)\+xml/.ignoresCase()),
        let href = tag.firstMatch(of: /href\s*=\s*["']([^"']+)["']/.ignoresCase())
      else { continue }
      return webURL(href.1.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)
    }
    return nil
  }

  // Only a web address is fetched or opened; a feed may name file or javascript links.
  static func webURL(_ string: String, relativeTo base: URL) -> URL? {
    let url = URL(string: string, relativeTo: base)?.absoluteURL
    return ["http", "https"].contains(url?.scheme?.lowercased()) ? url : nil
  }
}

// Reads RSS 2.0, RSS 1.0 and Atom: the feed's title and each item's link and title.
private final class FeedParser: NSObject, XMLParserDelegate {
  private struct Item {
    var link: URL?
    var title = ""
  }

  private let base: URL
  private var isFeed = false
  private var title: String?
  private var links: [LiveLink] = []
  private var item: Item?
  private var text = ""

  private init(base: URL) {
    self.base = base
  }

  // Nil for anything that is not a feed, such as a web page.
  static func parse(_ data: Data, base: URL) -> LiveFeed? {
    let delegate = FeedParser(base: base)
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), delegate.isFeed else { return nil }
    return LiveFeed(title: delegate.title, links: delegate.links)
  }

  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
    attributes: [String: String]
  ) {
    text = ""
    switch name {
    case "rss", "feed", "rdf:RDF":
      isFeed = true
    case "item", "entry":
      item = Item()
    // Atom's link is an attribute; an entry's page is its alternate link, the one without a rel.
    case "link" where item != nil && (attributes["rel"] ?? "alternate") == "alternate":
      if let href = attributes["href"] { item?.link = Feed.webURL(href, relativeTo: base) }
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
  }

  func parser(_ parser: XMLParser, foundCDATA data: Data) {
    text += String(decoding: data, as: UTF8.self)
  }

  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    text = ""
    switch name {
    case "title" where item != nil:
      item?.title = value
    // The channel's or feed's own title comes before any other.
    case "title" where title == nil:
      title = value
    // RSS's link is the element's text.
    case "link" where item != nil && item?.link == nil && !value.isEmpty:
      item?.link = Feed.webURL(value, relativeTo: base)
    case "item", "entry":
      if let item, let link = item.link {
        links.append(LiveLink(url: link, title: item.title.isEmpty ? link.absoluteString : item.title))
      }
      item = nil
    default:
      break
    }
  }
}
