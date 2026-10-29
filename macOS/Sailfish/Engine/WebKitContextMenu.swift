import AppKit
@preconcurrency import EngineCore
import WebKit

// What a right click on a WebKit page is on, as the isolated script's hit test reported it, for Sailfish's page menu.
struct WebKitContextMenu: PageMenuTarget {
  struct Hit: Sendable {
    let link: URL?
    let linkText: String
    let image: URL?
    let selection: String
    let isEditable: Bool
    let direction: NSWritingDirection

    // A click with no hit test: the page's own items.
    static let empty = Hit(link: nil, linkText: "", image: nil, selection: "", isEditable: false, direction: .natural)
  }

  let hit: Hit
  let page: WebKitPage
  // The right click, for Look Up at its point.
  let event: NSEvent

  var linkURL: URL? { hit.link }
  var linkText: String { hit.linkText }
  var imageURL: URL? { hit.image }
  var selectionText: String { hit.selection }
  var isEditable: Bool { hit.isEditable }
  var writingDirection: NSWritingDirection { hit.direction }

  var editFlags: ECEditFlags {
    var flags: ECEditFlags = []
    if page.webView.undoManager?.canUndo == true { flags.insert(.canUndo) }
    if page.webView.undoManager?.canRedo == true { flags.insert(.canRedo) }
    if !hit.selection.isEmpty {
      flags.insert(.canCopy)
      if hit.isEditable { flags.insert(.canCut) }
    }
    if hit.isEditable {
      flags.insert(.canSelectAll)
      if NSPasteboard.general.pasteboardItems?.isEmpty == false { flags.insert(.canPaste) }
    }
    return flags
  }

  func saveLink() {
    linkURL.map(page.saveTarget)
  }

  func saveImage() {
    imageURL.map(page.saveTarget)
  }

  // Fetches the image with the page's cookies and puts it on the pasteboard.
  func copyImage() {
    guard let url = imageURL else { return }
    let cookies = page.webView.configuration.websiteDataStore.httpCookieStore
    let referrer = page.url?.absoluteString
    Task {
      let configuration = URLSessionConfiguration.ephemeral
      for cookie in await cookies.allCookies() {
        configuration.httpCookieStorage?.setCookie(cookie)
      }
      var request = URLRequest(url: url)
      request.setValue(referrer, forHTTPHeaderField: "Referer")
      let session = URLSession(configuration: configuration)
      let data = try? await session.data(for: request).0
      session.finishTasksAndInvalidate()
      guard let image = data.flatMap(NSImage.init(data:)) else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects([image])
    }
  }

  // WebKit pages have no Inspect item: their hasDeveloperTools is false.
  func inspect() {}

  func lookUp() {
    page.webView.quickLook(with: event)
  }

  func setWritingDirection(_ direction: NSWritingDirection) {
    let action =
      direction == .rightToLeft
      ? #selector(NSTextView.makeBaseWritingDirectionRightToLeft(_:))
      : #selector(NSTextView.makeBaseWritingDirectionLeftToRight(_:))
    NSApp.sendAction(action, to: page.webView, from: nil)
  }
}

extension WebKitContextMenu.Hit {
  init(_ body: [String: Any]) {
    let url = { (key: String) in (body[key] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) } }
    link = url("link")
    linkText = body["linkText"] as? String ?? ""
    image = url("image")
    selection = body["selection"] as? String ?? ""
    isEditable = body["editable"] as? Bool ?? false
    direction =
      switch body["direction"] as? String {
      case "ltr": .leftToRight
      case "rtl": .rightToLeft
      default: .natural
      }
  }
}
