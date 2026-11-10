import XCTest

@testable import Sailfish

final class LinkSummaryTests: XCTestCase {
  func testAPageGivesItsTitleDescriptionAndTextWithoutScriptsOrMenus() {
    let page = PageText.extract(
      html: """
        <html><head><title> Shopify vs WooCommerce &amp; More </title>
        <meta property="og:description" content="Which store builder fits you?">
        <style>p { color: red }</style><script>var x = "<p>not this</p>";</script></head>
        <body><nav><a>Home</a> <a>Blog</a> <a>About us and more</a> <a>Contact</a></nav>
        <p>Shopify has fixed monthly costs for every plan.</p>
        <p>WooCommerce is free to use but needs&nbsp;hosting you pay for.</p>
        <footer>Copyright 2026 all rights reserved here</footer></body></html>
        """)
    XCTAssertEqual(page.title, "Shopify vs WooCommerce & More")
    XCTAssertEqual(page.description, "Which store builder fits you?")
    XCTAssertEqual(
      page.body,
      "Shopify has fixed monthly costs for every plan.\nWooCommerce is free to use but needs hosting you pay for.")
  }

  func testAPageWithAnArticleGivesTheArticleAlone() {
    let article = String(repeating: "The article says something worth reading here. ", count: 12)
    let page = PageText.extract(
      html: "<body><p>A sidebar line that is not the article.</p><article><p>\(article)</p></article></body>")
    XCTAssertEqual(page.body, article.trimmingCharacters(in: .whitespaces))
  }

  func testEntitiesAreDecoded() {
    XCTAssertEqual(PageText.decode("Tom &amp; Jerry &#8212; &#x2019;s &ldquo;show&rdquo; &bogus; & more"),
      "Tom & Jerry — ’s “show” &bogus; & more")
  }

  func testThePromptGivesTitleDescriptionAndTheStartOfTheText() {
    let page = PageText(title: "T", description: "D", body: String(repeating: "a", count: 10))
    XCTAssertEqual(page.prompt(limit: 4), "Title: T\nDescription: D\nPage text:\naaaa")
  }
}
