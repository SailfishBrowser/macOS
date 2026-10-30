import AppKit
@preconcurrency import EngineCore

struct ReaderArticle: Equatable, Decodable, Sendable {
  let title: String
  let byline: String?
  let content: String
  let lang: String?
  let dir: String?
}

// Mozilla's Readability, run in an isolated world on a clone of the document, so the
// page neither sees it nor changes.
enum ReaderScript {
  static let readerable = wrapped("Readability-readerable-0.6.0", "return String(isProbablyReaderable(document))")
  static let article = wrapped(
    "Readability-0.6.0",
    """
    const a = new Readability(document.cloneNode(true)).parse();
    return a && JSON.stringify({title: a.title, byline: a.byline, content: a.content, lang: a.lang, dir: a.dir});
    """)

  static func article(fromJSON json: String) -> ReaderArticle? {
    try? JSONDecoder().decode(ReaderArticle.self, from: Data(json.utf8))
  }

  private static func wrapped(_ library: String, _ body: String) -> String {
    let source = try! String(contentsOf: Bundle.main.url(forResource: library, withExtension: "js")!, encoding: .utf8)
    return "(() => {\n\(source)\n\(body)\n})()"
  }
}

extension Engine {
  // A page that finished loading, or moved to another URL without a load, is checked for an article; a new page
  // closes the reader.
  func updateReader(_ tab: UUID, _ shown: any TabPage, from previous: WebPage?, to page: WebPage) {
    let moved = previous?.url.flatMap { old in page.url.map { !old.isSamePage(as: $0) } } ?? true
    if moved {
      readers[tab] = nil
      readerable.remove(tab)
    }
    guard !page.isLoading, moved || previous?.isLoading == true, ["http", "https"].contains(page.url?.scheme) else {
      return
    }
    shown.evaluateJavaScript(ReaderScript.readerable) { result in
      MainActor.assumeIsolated {
        guard self.page(tab) === shown, shown.url == page.url else { return }
        if result == "true" {
          self.readerable.insert(tab)
        } else {
          self.readerable.remove(tab)
        }
      }
    }
  }

  func toggleReader(_ tab: UUID) {
    guard readers[tab] == nil else {
      readers[tab] = nil
      return
    }
    guard let shown = page(tab) else { return }
    let url = shown.url
    shown.evaluateJavaScript(ReaderScript.article) { json in
      MainActor.assumeIsolated {
        guard self.page(tab) === shown, shown.url == url, let json else { return }
        self.readers[tab] = ReaderScript.article(fromJSON: json)
      }
    }
  }
}
