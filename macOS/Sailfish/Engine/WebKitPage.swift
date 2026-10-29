import AppKit
import UniformTypeIdentifiers
import WebKit

// A tab's page rendered by WebKit, owning one web view.
@MainActor final class WebKitPage: NSObject, TabPage, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  let id: UUID
  let webView: WKWebView
  // Called on every change of the page's URL, title, loading, progress, history or security, and of its favicon.
  var onUpdate: (@MainActor (WebKitPage) -> Void)?
  private var observations: [NSKeyValueObservation] = []
  private var favicon: NSImage?
  // The icon the favicon was fetched from, or is being fetched from.
  private var iconURL: URL?
  private static let iconSession = URLSession(configuration: .ephemeral)
  private static let textDirectiveCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~")

  // `configuration` is the one WebKit passes for a popup, nil otherwise. It shares its opener's content controller,
  // and with it the opener's message handler, so the popup's page takes a controller of its own.
  init(id: UUID, profile: UUID, incognito: Bool, configuration: WKWebViewConfiguration?) {
    self.id = id
    let fresh = WebKitStores.configuration(profile: profile, incognito: incognito)
    let configuration = configuration ?? fresh
    configuration.userContentController = fresh.userContentController
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    fresh.userContentController.add(self, contentWorld: WebKitPageScript.world, name: "sailfish")
    // The window's two-finger swipe switches spaces.
    webView.allowsBackForwardNavigationGestures = false
    webView.allowsMagnification = true
    webView.isInspectable = !incognito
    observations = [
      observe(\.url), observe(\.title), observe(\.isLoading), observe(\.estimatedProgress), observe(\.canGoBack),
      observe(\.canGoForward), observe(\.hasOnlySecureContent),
    ]
  }

  private func observe<Value>(_ keyPath: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
    webView.observe(keyPath) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.changed() }
    }
  }

  private func changed() {
    onUpdate?(self)
  }

  var page: WebPage {
    WebPage(
      url: webView.url, title: title, favicon: favicon, isLoading: webView.isLoading, canGoBack: webView.canGoBack,
      canGoForward: webView.canGoForward)
  }

  // The page's title, or its URL while it has none, as Chromium's.
  private var title: String {
    webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? webView.url?.absoluteString ?? ""
  }

  // The current history entry's URL: a restored entry's from the moment it is restored, a new page's once it
  // commits.
  var committedURL: URL? {
    webView.backForwardList.currentItem?.url
  }

  // The page's history, nil while nothing has committed.
  var sessionState: Data? {
    committedURL == nil ? nil : webView.interactionState as? Data
  }

  // Gives the page its saved history and starts loading its current entry.
  func restore(_ state: Data) {
    webView.interactionState = state
  }

  func load(_ request: URLRequest) {
    webView.load(request)
  }

  func goBack() {
    webView.goBack()
  }

  func goForward() {
    webView.goForward()
  }

  // Goes to the entry at `index` in the whole history, oldest first; a stale index does nothing.
  func go(to index: Int) {
    let list = webView.backForwardList
    guard let item = list.item(at: index - list.backList.count) else { return }
    webView.go(to: item)
  }

  func reload() {
    webView.reload()
  }

  func close() {
    observations = []
    onUpdate = nil
    webView.configuration.userContentController.removeAllScriptMessageHandlers()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.stopLoading()
    webView.pauseAllMediaPlayback {}
    webView.closeAllMediaPresentations {}
    webView.removeFromSuperview()
  }

  // The entries behind the current one, nearest first, indexed in the whole history as `go(to:)` takes them.
  var backEntries: [HistoryEntry] {
    let back = webView.backForwardList.backList
    return back.indices.reversed().map { entry(back[$0], index: $0) }
  }

  var forwardEntries: [HistoryEntry] {
    let list = webView.backForwardList
    let current = list.backList.count
    return list.forwardList.enumerated().map { entry($1, index: current + 1 + $0) }
  }

  private func entry(_ item: WKBackForwardListItem, index: Int) -> HistoryEntry {
    HistoryEntry(
      page: id, index: index, url: item.url, title: item.title.flatMap { $0.isEmpty ? nil : $0 } ?? item.url.absoluteString)
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.frameInfo.isMainFrame, case let .icons(icons)? = PageScriptMessage(message.body), let icon = icons.first {
      fetchFavicon(icon)
    }
  }

  // Fetches the page's icon once; a later page with the same icon keeps it.
  private func fetchFavicon(_ url: URL) {
    guard url != iconURL else { return }
    iconURL = url
    Task {
      let data = try? await Self.iconSession.data(from: url).0
      guard iconURL == url else { return }
      favicon = data.flatMap { NSImage(data: $0) }
      onUpdate?(self)
    }
  }

  // MARK: TabPage

  var view: NSView { webView }
  var url: URL? { webView.url }
  var isSecure: Bool { webView.url?.scheme == "https" && webView.hasOnlySecureContent }
  var hasDeveloperTools: Bool { false }
  var translationLanguage: String? { nil }

  // Runs `script` in the main frame in Sailfish's content world, giving its result if it is a string.
  func evaluateJavaScript(_ script: String, completion: @escaping @MainActor (String?) -> Void) {
    webView.evaluateJavaScript(script, in: nil, in: WebKitPageScript.world) { completion(try? $0.get() as? String) }
  }

  func snapshot(_ completion: @escaping @MainActor (NSImage?) -> Void) {
    webView.takeSnapshot(with: nil) { image, _ in completion(image) }
  }

  // The page's URL with a text fragment for the main frame's selection: the whole text when it is one short line,
  // otherwise its first and last few words as a range.
  func linkToHighlight(_ completion: @escaping @MainActor (URL?) -> Void) {
    evaluateJavaScript("String(getSelection())") { [weak self] text in
      completion(self?.webView.url.flatMap { Self.highlightLink(to: text ?? "", on: $0) })
    }
  }

  private static func highlightLink(to text: String, on url: URL) -> URL? {
    let lines = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }
      .filter { !$0.isEmpty }
    guard let first = lines.first, let last = lines.last,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    let parts = lines.count == 1 && first.count <= 8 ? [first[...]] : [first.prefix(4), last.suffix(4)]
    let directive = parts.compactMap {
      $0.joined(separator: " ").addingPercentEncoding(withAllowedCharacters: textDirectiveCharacters)
    }
    components.fragment = nil
    return components.string.flatMap { URL(string: $0 + "#:~:text=" + directive.joined(separator: ",")) }
  }

  func scrollSelectionIntoView() {
    evaluateJavaScript(
      """
      (() => {
        const selection = getSelection();
        if (!selection.rangeCount) return;
        const range = selection.getRangeAt(0);
        const start = range.getClientRects()[0] || range.getBoundingClientRect();
        scrollBy(0, start.top - innerHeight / 2);
      })()
      """
    ) { _ in }
  }

  func stop() {
    webView.stopLoading()
  }

  func reloadBypassingCache() {
    webView.reloadFromOrigin()
  }

  // Asks where to save the page, then saves it as a web archive.
  func savePage() {
    guard let window = webView.window else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.webArchive]
    panel.nameFieldStringValue = title.replacing("/", with: "-").replacing(":", with: "-")
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let file = panel.url else { return }
      self?.webView.createWebArchiveData { try? $0.get().write(to: file) }
    }
  }

  func printPage() {
    guard let window = webView.window else { return }
    let operation = webView.printOperation(with: .shared)
    // WebKit paginates at the operation view's size, which starts empty.
    operation.view?.frame = webView.bounds
    operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
  }

  // WebKit pages offer no translation: their translationLanguage is nil.
  func translate() {}

  // WebKit pages have no developer tools of Sailfish's: hasDeveloperTools is false.
  func showConsole() {}
  func inspectElement() {}

  func perform(_ command: EditCommand) {
    switch command {
    case .undo: webView.undoManager?.undo()
    case .redo: webView.undoManager?.redo()
    case .cut: NSApp.sendAction(#selector(NSText.cut(_:)), to: webView, from: nil)
    case .copy: NSApp.sendAction(#selector(NSText.copy(_:)), to: webView, from: nil)
    case .paste: NSApp.sendAction(#selector(NSText.paste(_:)), to: webView, from: nil)
    case .pasteAndMatchStyle: NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: webView, from: nil)
    case .selectAll: NSApp.sendAction(#selector(NSText.selectAll(_:)), to: webView, from: nil)
    }
  }
}
