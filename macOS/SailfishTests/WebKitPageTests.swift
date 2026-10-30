import WebKit
import XCTest

@testable import Sailfish

@MainActor
final class WebKitPageTests: XCTestCase {
  func testOnlyOtherAppsSchemesLeaveThePage() {
    for url in ["https://netflix.com", "HTTP://a.com", "blob:https://a.com/1", "data:text/plain,a", "about:blank"] {
      XCTAssertTrue(WebKitPage.rendersInPage(URL(string: url)!), url)
    }
    for url in ["mailto:a@b.c", "spotify:track:1", "t3code://done", "tel:123"] {
      XCTAssertFalse(WebKitPage.rendersInPage(URL(string: url)!), url)
    }
  }

  func testAnOriginIsSpelledAsThePageSpellsIt() {
    XCTAssertEqual(PasswordFill.serialized(URL(string: "https://a.com/")!), "https://a.com")
    XCTAssertEqual(PasswordFill.serialized(URL(string: "http://a.com:8080/")!), "http://a.com:8080")
  }

  // The password script on a real page: no form is reported before the user acts, and a login goes only to its origin.
  func testALoginWaitsForTheUserAndStaysOnItsOrigin() async throws {
    let messages = Messages()
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(messages, contentWorld: PasswordFill.world, name: PasswordFill.handlerName)
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: PasswordFill.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: PasswordFill.world))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [], backing: .buffered, defer: false)
    let webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
    window.contentView!.addSubview(webView)
    let loaded = expectation(description: "loaded")
    let delegate = Loaded { loaded.fulfill() }
    webView.navigationDelegate = delegate
    webView.loadHTMLString(
      "<form><input id=u type=text><input id=p type=password></form>", baseURL: URL(string: "https://a.example/"))
    await fulfillment(of: [loaded], timeout: 10)

    func password() async throws -> String {
      try await webView.evaluateJavaScript("document.getElementById('p').value") as? String ?? ""
    }
    func fill(_ origin: String) async throws {
      _ = try await webView.callAsyncJavaScript(
        "sailfishFill(origin, 0, 'me', 'secret', true)", arguments: ["origin": origin], in: nil, contentWorld: PasswordFill.world)
    }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(messages.bodies.isEmpty)

    try await fill("https://b.example")
    let elsewhere = try await password()
    XCTAssertEqual(elsewhere, "")

    try await fill("https://a.example")
    let here = try await password()
    XCTAssertEqual(here, "secret")
  }
}

private final class Messages: NSObject, WKScriptMessageHandler {
  var bodies: [Any] = []
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    bodies.append(message.body)
  }
}

private final class Loaded: NSObject, WKNavigationDelegate {
  let done: () -> Void
  init(_ done: @escaping () -> Void) { self.done = done }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}
