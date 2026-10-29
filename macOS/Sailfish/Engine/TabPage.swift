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
