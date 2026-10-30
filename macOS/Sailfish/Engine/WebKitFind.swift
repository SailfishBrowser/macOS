import AppKit
@preconcurrency import EngineCore
import WebKit

// A find bar request, for either engine.
enum FindOperation {
  // The next or previous match, or a new search when the string changed.
  case find(String, forward: Bool)
  // As typed: a changed string starts a new search, the same one reports its results again.
  case findAsTyped(String)
  // Ends finding and keeps the active match selected.
  case stop
}

// Find in a WebKit page, drawn and reported as Chromium's is: the isolated script finds the matches in the main
// frame's text, marks every one with the active one stronger, scrolls the active one into view and keeps it selected
// when finding stops, and the scrollbar shows a tick at each match. A new search starts at the first match from the
// top, and on a long page its count and ticks arrive as the script marks the rest.
@MainActor final class WebKitFind {
  // Bumped by each call and when finding ends, so answers and reports for the calls before are dropped.
  private var generation = 0
  private let ticks = WebKitFindTicks()

  func perform(_ operation: FindOperation, in page: WebKitPage) {
    switch operation {
    case let .find(string, forward): search(string, step: forward ? 1 : -1, in: page)
    case let .findAsTyped(string): search(string, step: 0, in: page)
    case .stop:
      end()
      page.webView.evaluateJavaScript("window.__sailfish.stopFinding()", in: nil, in: WebKitPageScript.world)
    }
  }

  // A new page has no marks, so its next find searches again.
  func end() {
    generation += 1
    ticks.removeFromSuperview()
  }

  private func search(_ string: String, step: Int, in page: WebKitPage) {
    generation += 1
    let generation = self.generation
    page.webView.callAsyncJavaScript(
      "return window.__sailfish.find(text, step, id)", arguments: ["text": string, "step": step, "id": generation],
      in: nil, in: WebKitPageScript.world
    ) { [weak self, weak page] result in
      guard let self, let page, generation == self.generation else { return }
      // A page whose script did not run has no matches.
      let answer = (try? result.get()) as? [Any] ?? [0, 0, NSNull()]
      report(matches: answer[0] as? Int ?? 0, active: answer[1] as? Int ?? 0, ticks: answer[2] as? [Double], in: page)
    }
  }

  // The script's count so far for call `id`, and the ticks once every match is marked.
  func update(id: Int, matches: Int, active: Int, ticks: [Double]?, in page: WebKitPage) {
    guard id == generation else { return }
    report(matches: matches, active: active, ticks: ticks, in: page)
  }

  private func report(matches: Int, active: Int, ticks: [Double]?, in page: WebKitPage) {
    if let ticks {
      showTicks(ticks, in: page.webView)
    }
    Engine.shared.webKitPage(page, didFindMatches: matches, activeMatch: active)
  }

  private func showTicks(_ positions: [Double], in webView: WKWebView) {
    ticks.positions = positions.shuffled()
    guard !positions.isEmpty else { return ticks.removeFromSuperview() }
    let width = WebKitFindTicks.width
    ticks.frame = NSRect(x: webView.bounds.width - width, y: 0, width: width, height: webView.bounds.height)
    ticks.autoresizingMask = [.minXMargin, .height]
    webView.addSubview(ticks)
  }
}

// The find ticks along a WebKit page's right edge, drawn as Chromium draws them in its scrollbar: a bar 3 points tall
// across the scrollbar's width, orange edged with a yellow core, as far down the edge as its match is down the page.
// Chromium draws them from a hash set, in no fixed order, so close ticks overlap in the same mix of edge and core.
final class WebKitFindTicks: NSView {
  static let width: CGFloat = 15
  private static let edge = NSColor(srgbRed: 0xB0 / 255, green: 0x60 / 255, blue: 0, alpha: 1)
  private static let core = NSColor(srgbRed: 1, green: 0xDD / 255, blue: 0, alpha: 1)

  var positions: [Double] = [] {
    didSet { needsDisplay = true }
  }

  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    for position in positions {
      let tick = NSRect(x: 0, y: (bounds.height * position).rounded(.down), width: bounds.width, height: 3)
      Self.edge.setFill()
      tick.fill()
      Self.core.setFill()
      tick.insetBy(dx: 1, dy: 1).fill()
    }
  }
}

extension FindOperation {
  func perform(on contents: ECWebContents) {
    switch self {
    case let .find(string, forward): contents.find(string, forward: forward)
    case let .findAsTyped(string): contents.find(string)
    case .stop: contents.stopFinding()
    }
  }
}

// Page zoom in WebKit pages, in Chrome's steps and remembered per host in the Chromium context's zoom map, so a
// site keeps one zoom in both engines.
extension Engine {
  static let zoomFactors: [Double] = [0.25, 1 / 3, 0.5, 2 / 3, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

  func webKitPage(_ page: WebKitPage, didFindMatches matches: Int, activeMatch: Int) {
    guard let tab = shownTab(of: page) else { return }
    Self.continuation.yield(.found(tab: tab, matches: matches, activeMatch: activeMatch))
  }

  // Steps the page's zoom and writes it for its host, which every open page of the host in both engines takes.
  func zoom(_ page: WebKitPage, of tab: UUID, _ step: ZoomStep) -> Int? {
    guard let context = tabContexts[tab], let host = page.webView.url?.host() else { return nil }
    let current = Double(page.webView.pageZoom)
    let factor: Double =
      switch step {
      case .in: Self.zoomFactors.first { $0 > current + 0.001 } ?? current
      case .out: Self.zoomFactors.last { $0 < current - 0.001 } ?? current
      case .reset: 1
      }
    let percent = Int((factor * 100).rounded())
    context.setZoomPercent(percent, forHost: host)
    applyZoom(percent, host: host, in: context)
    return percent
  }

  // Every open WebKit page of the host takes its zoom at once, as Chromium's pages of the host do.
  func applyZoom(_ percent: Int, host: String, in context: ECBrowserContext) {
    for live in livePages.values {
      guard let live = live as? WebKitPage, let owner = owners[ObjectIdentifier(live)],
        tabContexts[owner.tab] === context, live.webView.url?.host() == host
      else { continue }
      applyZoom(percent, to: live)
    }
  }

  // A committed page takes its host's zoom.
  func webKitPageDidCommit(_ page: WebKitPage) {
    page.finder.end()
    guard let tab = tab(of: page), let context = tabContexts[tab], let host = page.webView.url?.host() else { return }
    applyZoom(context.zoomPercent(forHost: host), to: page)
  }

  private func applyZoom(_ percent: Int, to page: WebKitPage) {
    let factor = Self.zoomFactors.first { Int(($0 * 100).rounded()) == percent } ?? Double(percent) / 100
    guard page.webView.pageZoom != factor else { return }
    page.webView.pageZoom = factor
    if let tab = shownTab(of: page) {
      Self.continuation.yield(.zoomChanged(tab: tab, percent: percent))
    }
  }
}
