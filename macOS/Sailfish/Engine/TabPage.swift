import AppKit
@preconcurrency import EngineCore

// A tab's page as the views and menus reach it, whichever engine renders it.
@MainActor protocol TabPage: AnyObject {
  var view: NSView { get }
  var url: URL? { get }
  var isSecure: Bool { get }
  var hasDeveloperTools: Bool { get }
  var translationLanguage: String? { get }
  func evaluateJavaScript(_ script: String, completion: @escaping @MainActor (String?) -> Void)
  func snapshot(_ completion: @escaping @MainActor (NSImage?) -> Void)
  func linkToHighlight(_ completion: @escaping @MainActor (URL?) -> Void)
  func scrollSelectionIntoView()
  func stop()
  func reloadBypassingCache()
  func savePage()
  func printPage()
  func translate()
  func showConsole()
  func inspectElement()
  func perform(_ command: EditCommand)
  // What the tab's page list drives: the page's own history, its state as the tab reports it, and its end.
  var loadProgress: Double { get }
  var canGoBack: Bool { get }
  var canGoForward: Bool { get }
  var sessionState: Data? { get }
  func history(of page: UUID) -> PageHistory
  func webPage(pages: [PageRecord], shown: Int) -> WebPage
  func goBack()
  func goForward()
  func go(to index: Int)
  func reload()
  func close()
}

enum EditCommand {
  case undo, redo, cut, copy, paste, pasteAndMatchStyle, selectAll
}

// An entry of a back or forward menu: its index in the history of the page it belongs to.
struct HistoryEntry: Equatable, Sendable {
  let page: UUID
  let index: Int
  let url: URL
  let title: String
}

// A page's own history, nearest first, with the entry it is at.
struct PageHistory {
  let back: [HistoryEntry]
  let current: HistoryEntry?
  let forward: [HistoryEntry]
}

// What a page's context menu was opened on.
@MainActor protocol PageMenuTarget {
  var linkURL: URL? { get }
  var linkText: String { get }
  var imageURL: URL? { get }
  var selectionText: String { get }
  var isEditable: Bool { get }
  var editFlags: ECEditFlags { get }
  var writingDirection: NSWritingDirection { get }
  func saveLink()
  func saveImage()
  func copyImage()
  func inspect()
  func lookUp()
  func setWritingDirection(_ direction: NSWritingDirection)
}

// The engine's completion handlers run on the main thread.
extension ECWebContents: TabPage {
  var hasDeveloperTools: Bool { true }

  func evaluateJavaScript(_ script: String, completion: @escaping @MainActor (String?) -> Void) {
    let done: @Sendable (String?) -> Void = { result in MainActor.assumeIsolated { completion(result) } }
    evaluateJavaScript(script, completion: done)
  }

  func snapshot(_ completion: @escaping @MainActor (NSImage?) -> Void) {
    let done: @Sendable (NSImage?) -> Void = { image in MainActor.assumeIsolated { completion(image) } }
    snapshot(done)
  }

  func linkToHighlight(_ completion: @escaping @MainActor (URL?) -> Void) {
    let done: @Sendable (URL?) -> Void = { url in MainActor.assumeIsolated { completion(url) } }
    linkToHighlight(done)
  }

  func printPage() {
    self.print()
  }

  func history(of page: UUID) -> PageHistory {
    let back = backEntries
    let entry = { (item: ECNavigationEntry) in HistoryEntry(page: page, index: item.index, url: item.url, title: item.title) }
    return PageHistory(
      back: back.map(entry),
      current: url.map { HistoryEntry(page: page, index: back.first.map { $0.index + 1 } ?? 0, url: $0, title: title) },
      forward: forwardEntries.map(entry))
  }

  func webPage(pages: [PageRecord], shown: Int) -> WebPage {
    WebPage(
      url: url, title: title, favicon: favicon, isLoading: isLoading, canGoBack: canGoBack, canGoForward: canGoForward,
      isAudible: isAudible, isMuted: isMuted, media: media, pages: pages, shownPage: shown)
  }

  // The entry is looked up again by its index, as a menu's copy may be stale.
  func go(to index: Int) {
    guard let entry = (backEntries + forwardEntries).first(where: { $0.index == index }) else { return }
    go(to: entry)
  }

  func perform(_ command: EditCommand) {
    switch command {
    case .undo: undo(nil)
    case .redo: redo(nil)
    case .cut: cut(nil)
    case .copy: copy(nil)
    case .paste: paste(nil)
    case .pasteAndMatchStyle: pasteAndMatchStyle(nil)
    case .selectAll: selectAll(nil)
    }
  }
}

extension ECContextMenu: PageMenuTarget {}
