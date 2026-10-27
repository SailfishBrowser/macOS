import WebKit
import XCTest

@testable import Sailfish

// The scripts the engine runs, run here in WebKit's own isolated world on Readability fixtures.
@MainActor
final class ReaderTests: XCTestCase {
  private final class LoadWatcher: NSObject, WKNavigationDelegate {
    var loaded: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loaded?.resume()
      loaded = nil
    }
  }

  private let watcher = LoadWatcher()

  private func page(_ fixture: String) async throws -> WKWebView {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "html"))
    let page = WKWebView()
    page.navigationDelegate = watcher
    await withCheckedContinuation { continuation in
      watcher.loaded = continuation
      page.loadHTMLString(try! String(contentsOf: url, encoding: .utf8), baseURL: URL(string: "https://example.test/article"))
    }
    return page
  }

  private func run(_ script: String, in page: WKWebView) async throws -> String? {
    try await page.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? String
  }

  // Mozilla's test page 001 and its expected metadata (mozilla/readability test/test-pages/001 at 0.6.0).
  func testAnArticleIsReaderableAndGivesItsTitleBylineAndText() async throws {
    let page = try await page("readability-001")
    let readerable = try await run(ReaderScript.readerable, in: page)
    XCTAssertEqual(readerable, "true")

    let json = try await run(ReaderScript.article, in: page)
    let article = try XCTUnwrap(json.flatMap(ReaderScript.article(fromJSON:)))
    XCTAssertEqual(article.title, "Get your Frontend JavaScript Code Covered | Code")
    XCTAssertEqual(article.byline, "Nicolas Perriault")
    XCTAssertEqual(article.lang, "en")
    XCTAssertNil(article.dir)
    XCTAssertTrue(article.content.contains("The idea behind code coverage is to record which parts of your code"))
  }

  func testAFormWithNoProseIsNotReaderable() async throws {
    let page = try await page("app-form")
    let readerable = try await run(ReaderScript.readerable, in: page)
    XCTAssertEqual(readerable, "false")
  }

  // The page keeps every node and never sees the library.
  func testExtractionLeavesThePageUntouched() async throws {
    let page = try await page("readability-001")
    let count = "String(document.getElementsByTagName('*').length)"
    let before = try await page.evaluateJavaScript(count) as? String
    _ = try await run(ReaderScript.article, in: page)
    let after = try await page.evaluateJavaScript(count) as? String
    XCTAssertEqual(after, before)
    let seen = try await page.evaluateJavaScript("typeof Readability + typeof isProbablyReaderable") as? String
    XCTAssertEqual(seen, "undefinedundefined")
  }

  func testTheDocumentEscapesTheTitleAndCarriesTheSettings() {
    let article = ReaderArticle(title: "A <b> & \"c\"", byline: "Me", content: "<p>Body</p>", lang: "en", dir: nil)
    let html = ReaderDocument.html(article, ReaderSettings(step: 0, isSerif: false, theme: .sepia))
    XCTAssertTrue(html.contains("<h1>A &lt;b&gt; &amp; &quot;c&quot;</h1>"))
    XCTAssertTrue(html.contains(#"data-theme="sepia" data-font="sans""#))
    XCTAssertTrue(html.contains("--size: 14px"))
    XCTAssertTrue(html.contains("<p>Body</p>"))
  }
}
