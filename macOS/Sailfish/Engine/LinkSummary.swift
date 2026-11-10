import Foundation
import FoundationModels

// A linked page's words, read without opening it: its title, its description and the text of its main content.
struct PageText: Equatable, Sendable {
  var title: String?
  var description: String?
  var body: String

  enum Failure: Error {
    case unsupported, unreadable
  }

  // The page at `url`, fetched in a session that keeps no cookies or cache, so a preview leaves nothing behind.
  static func fetch(_ url: URL) async throws -> PageText {
    guard url.scheme == "https" || url.scheme == "http" else { throw Failure.unsupported }
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.setValue("text/html,text/plain;q=0.9", forHTTPHeaderField: "Accept")
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
      forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw Failure.unreadable
    }
    let mime = http.mimeType ?? "text/html"
    guard mime == "text/html" || mime == "application/xhtml+xml" || mime == "text/plain" else {
      throw Failure.unsupported
    }
    let text = String(decoding: data.prefix(1_500_000), as: UTF8.self)
    let page = mime == "text/plain" ? PageText(body: clean(text)) : extract(html: text)
    guard page.body.count > 80 || page.description != nil else { throw Failure.unreadable }
    return page
  }

  private static let session = URLSession(configuration: .ephemeral)

  // The page's title, its description meta tag and the text of its article, or of its main or body when it has none.
  // Scripts, styles and the page's navigation, header, footer, forms and asides are left out.
  static func extract(html: String) -> PageText {
    // Inline scripts and styles can fill the first megabyte, so they go before the page is cut to length.
    var html = replacing(#"<!--[\s\S]*?-->"#, in: html, with: " ")
    html = replacing(#"<(script|style|noscript|svg|template)\b[^>]*>[\s\S]*?</\1\s*>"#, in: html, with: " ")
    html = String(html.prefix(400_000))
    let title = first(#"<title[^>]*>([\s\S]*?)</title\s*>"#, in: html).map(decode).map(collapse)
    let description = metaDescription(in: html)
    html = replacing(
      #"<(iframe|nav|header|footer|form|aside|button|select)\b[^>]*>[\s\S]*?</\1\s*>"#, in: html, with: " ")
    // The first article, as related posts often follow it in articles of their own.
    let main = [#"<article\b[^>]*>([\s\S]*?)</article\s*>"#, #"<main\b[^>]*>([\s\S]*)</main\s*>"#]
      .lazy.compactMap { first($0, in: html) }.map(text).first { $0.count >= 400 }
    return PageText(
      title: title.flatMap { $0.isEmpty ? nil : $0 }, description: description,
      body: main ?? text(of: first(#"<body\b[^>]*>([\s\S]*)</body\s*>"#, in: html) ?? html))
  }

  // What the model reads: the title, the description and the start of the text, short enough for its context.
  func prompt(limit: Int = 4000) -> String {
    [
      title.map { "Title: \($0)" },
      description.map { "Description: \($0)" },
      body.isEmpty ? nil : "Page text:\n" + String(body.prefix(limit)),
    ].compactMap(\.self).joined(separator: "\n")
  }

  // Markup to lines of text: a block element ends a line, and lines of fewer than four words, mostly menus and
  // buttons, are dropped.
  private static func text(of html: String) -> String {
    let broken = replacing(#"<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article|/blockquote|/pre|/dd|/dt)\b[^>]*>"#, in: html, with: "\n")
    return clean(decode(replacing(#"<[^>]+>"#, in: broken, with: " ")))
  }

  private static func clean(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline)
      .map { collapse(String($0)) }
      .filter { $0.split(separator: " ").count >= 4 }
      .joined(separator: "\n")
  }

  private static func collapse(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func metaDescription(in html: String) -> String? {
    for tag in matches(#"<meta\b[^>]*>"#, in: html) {
      var attributes: [String: String] = [:]
      for match in groups(#"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: tag) {
        attributes[match[0].lowercased()] = match[1].isEmpty ? match[2] : match[1]
      }
      let name = (attributes["name"] ?? attributes["property"])?.lowercased()
      if name == "description" || name == "og:description", let content = attributes["content"] {
        let text = collapse(decode(content))
        if !text.isEmpty { return text }
      }
    }
    return nil
  }

  static func decode(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var out = ""
    var rest = text[...]
    while let amp = rest.firstIndex(of: "&") {
      out += rest[..<amp]
      rest = rest[amp...]
      guard let semi = rest.prefix(12).firstIndex(of: ";") else {
        out.append("&")
        rest = rest.dropFirst()
        continue
      }
      let entity = rest[rest.index(after: rest.startIndex)..<semi]
      if let character = character(for: entity) {
        out.append(character)
        rest = rest[rest.index(after: semi)...]
      } else {
        out.append("&")
        rest = rest.dropFirst()
      }
    }
    return out + rest
  }

  private static func character(for entity: Substring) -> Character? {
    if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
      return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(Character.init)
    }
    if entity.hasPrefix("#") {
      return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map(Character.init)
    }
    return named[String(entity)]
  }

  private static let named: [String: Character] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–",
    "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "trade": "™",
    "middot": "·", "bull": "•", "laquo": "«", "raquo": "»", "eacute": "é", "egrave": "è", "agrave": "à",
  ]

  private static func regex(_ pattern: String) -> NSRegularExpression {
    // The patterns are constants above, so they always compile.
    try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }

  private static func first(_ pattern: String, in text: String) -> String? {
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex(pattern).firstMatch(in: text, range: range), match.numberOfRanges > 1,
      let found = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[found])
  }

  private static func matches(_ pattern: String, in text: String) -> [String] {
    regex(pattern).matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      Range($0.range, in: text).map { String(text[$0]) }
    }
  }

  // Each match's capture groups, with "" for a group that took no part.
  private static func groups(_ pattern: String, in text: String) -> [[String]] {
    regex(pattern).matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
      (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
  }

  private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
    regex(pattern).stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
  }
}

// One line of a preview: a short label and a sentence, as in "Price: Shopify has fixed monthly costs."
struct SummaryPoint: Equatable, Sendable {
  var label: String
  var text: String
}

// The model's answer, held by guided generation to labelled points, which free text did not reliably keep.
@available(macOS 26, *)
@Generable
struct PreviewAnswer {
  @Guide(description: "Three to five points about what the page says, the most useful first", .count(3...5))
  var points: [Point]

  @Generable
  struct Point {
    @Guide(description: "One to three words naming what the point is about, such as Price or Setting Up")
    var label: String
    @Guide(description: "One plain sentence of at most 15 words about it, taken from the page")
    var sentence: String
  }
}

@available(macOS 26, *)
extension PreviewAnswer.PartiallyGenerated {
  // The points as far as they have streamed.
  var summaryPoints: [SummaryPoint] {
    (points ?? []).compactMap { point in
      let label = point.label ?? "", text = point.sentence ?? ""
      return label.isEmpty && text.isEmpty ? nil : SummaryPoint(label: label, text: text)
    }
  }
}

// Previews of linked pages, written by Apple's on-device model, so nothing read leaves the Mac. The last 50 are kept,
// so a link previewed again shows at once.
@available(macOS 26, *)
@MainActor
final class LinkSummaries {
  static let shared = LinkSummaries()

  enum State: Equatable {
    case reading
    case writing([SummaryPoint])
    case done([SummaryPoint])
    case failed(String)
  }

  static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

  private var cache: [URL: [SummaryPoint]] = [:]
  private var order: [URL] = []

  // The preview of `url` as it is read and written. Ending the stream's iteration cancels the work.
  func summary(of url: URL) -> AsyncStream<State> {
    AsyncStream { continuation in
      let task = Task { @MainActor in
        defer { continuation.finish() }
        if let points = cache[url] {
          continuation.yield(.done(points))
          return
        }
        continuation.yield(.reading)
        do {
          let page = try await PageText.fetch(url)
          let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
          guard model.isAvailable else {
            continuation.yield(.failed("Previews need Apple Intelligence."))
            return
          }
          let session = LanguageModelSession(model: model, instructions: Self.instructions)
          var points: [SummaryPoint] = []
          let stream = session.streamResponse(
            to: page.prompt(), generating: PreviewAnswer.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 400))
          for try await snapshot in stream {
            points = snapshot.content.summaryPoints
            if !points.isEmpty { continuation.yield(.writing(points)) }
          }
          guard !points.isEmpty else {
            continuation.yield(.failed("No preview for this page."))
            return
          }
          remember(points, for: url)
          continuation.yield(.done(points))
        } catch is CancellationError {
        } catch PageText.Failure.unsupported {
          continuation.yield(.failed("No preview for this kind of link."))
        } catch let error as LanguageModelSession.GenerationError {
          switch error {
          case .guardrailViolation, .refusal:
            continuation.yield(.failed("No preview for this page."))
          default:
            continuation.yield(.failed("Couldn’t write a preview."))
          }
        } catch {
          if !Task.isCancelled { continuation.yield(.failed("Couldn’t read this page.")) }
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func remember(_ points: [SummaryPoint], for url: URL) {
    if cache.updateValue(points, forKey: url) == nil { order.append(url) }
    while order.count > 50 { cache[order.removeFirst()] = nil }
  }

  private static let instructions = """
    You preview web pages for someone deciding whether to open a link. Give the page's main points: what it is \
    about and what it says, in the language of the page. Do not repeat the title or the description word for word.
    """
}
