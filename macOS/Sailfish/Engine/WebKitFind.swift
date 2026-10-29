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

// Find in a WebKit page, reported as Chromium's is: WebKit selects each match, wrapping at the ends, and the isolated
// script counts the matches in the main frame's text. A new search starts at the first match from the top.
@MainActor final class WebKitFind {
  private var text = ""
  // Steps taken since the search started, backwards negative; the active match is this modulo the count.
  private var step = 0
  private var count: Int?
  // Whether WebKit found the string, and at which step, as the last answered find says.
  private var found: (matchFound: Bool, step: Int)?
  // Bumped by every new search, so answers to an older one are dropped.
  private var generation = 0

  func perform(_ operation: FindOperation, in page: WebKitPage) {
    switch operation {
    case let .find(string, forward):
      guard string == text, !string.isEmpty else { return start(string, forward: forward, in: page) }
      step += forward ? 1 : -1
      search(in: page, backwards: !forward)
    case let .findAsTyped(string):
      guard string == text, !string.isEmpty else { return start(string, forward: true, in: page) }
      report(page)
    case .stop:
      end()
    }
  }

  // A new page has nothing found yet, so the next find searches again.
  func end() {
    generation += 1
    text = ""
    count = nil
    found = nil
  }

  // Clears the selection, so WebKit's search starts at the top of the page, and counts the matches before searching;
  // an empty string only clears.
  private func start(_ string: String, forward: Bool, in page: WebKitPage) {
    end()
    text = string
    step = forward ? 0 : -1
    let generation = self.generation
    page.webView.callAsyncJavaScript(
      "getSelection().removeAllRanges(); return window.__sailfish.count(text)", arguments: ["text": string], in: nil,
      in: WebKitPageScript.world
    ) { [weak self, weak page] result in
      guard let self, let page, generation == self.generation else { return }
      // A page whose script did not run has no count; WebKit's own answer then decides.
      self.count = (try? result.get()) as? Int ?? 0
      guard !string.isEmpty else {
        self.found = (false, 0)
        return self.report(page)
      }
      self.search(in: page, backwards: !forward)
    }
  }

  private func search(in page: WebKitPage, backwards: Bool) {
    let configuration = WKFindConfiguration()
    configuration.backwards = backwards
    configuration.caseSensitive = false
    configuration.wraps = true
    let generation = self.generation
    let step = self.step
    page.webView.find(text, configuration: configuration) { [weak self, weak page] result in
      guard let self, let page, generation == self.generation else { return }
      self.found = (result.matchFound, step)
      self.report(page)
    }
  }

  // Reports once the count and a find have answered; a search still waiting reports when they do.
  private func report(_ page: WebKitPage) {
    guard let count, let found else { return }
    let matches = found.matchFound ? max(count, 1) : 0
    let active = matches == 0 ? 0 : (found.step % matches + matches) % matches + 1
    Engine.shared.webKitPage(page, didFindMatches: matches, activeMatch: active)
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
