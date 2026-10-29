import AppKit
@preconcurrency import EngineCore
import WebKit

extension Engine {
  // The registrable domain of the URL's host, which a tab's engine choice holds to.
  func siteOf(_ url: URL) -> String {
    ECEngine.registrableDomain(forHost: url.host() ?? "")
  }

  // A WebKit page of the tab, given its saved history if it has one; `configuration` is the one WebKit passes for a
  // popup.
  @discardableResult
  func makeWebKitPage(
    _ tab: UUID, page id: UUID, profile: UUID, configuration: WKWebViewConfiguration? = nil
  ) -> WebKitPage {
    let page = WebKitPage(id: id, profile: profile, incognito: incognitoTabs.contains(tab), configuration: configuration)
    page.onUpdate = { [weak self] in self?.webKitPageDidUpdate($0) }
    livePages[id] = page
    owners[ObjectIdentifier(page)] = (tab, id)
    if let state = Self.webKitSessions.load(id) {
      page.restore(state)
      restoredPages.insert(id)
      restoringPages.insert(id)
    }
    return page
  }

  // Hands the tab to `engine`: the pages after the shown one close, the shown one stays behind the new page with its
  // media paused (or is dropped when nothing committed in it), and a new page of `engine`, muted as the tab is, loads
  // the request. The tab's choice keeps it in that engine while it stays on the request's site.
  func switchEngine(_ tab: UUID, to engine: PageEngineKind, request: URLRequest) async {
    guard var pages = pageRecords[tab], let shown = shownPages[tab], let context = tabContexts[tab],
      let profile = tabProfiles[tab], let url = request.url
    else { return }
    choices[tab] = EngineChoice(engine: engine, site: siteOf(url))
    pages[(shown + 1)...].forEach { dropPage($0) }
    pages.removeSubrange((shown + 1)...)
    let left = pages[shown]
    let muted = livePages[left.id]?.isMuted == true
    if let page = livePages[left.id], page.sessionState != nil {
      hold(tab, left.id)
      page.pauseMedia()
    } else {
      permissionRequests.removeValue(forKey: tab)?.answer(false)
      dialogs.removeValue(forKey: tab)?.answer(false, "")
      dropPage(pages.removeLast())
    }
    let record = PageRecord(id: UUID(), engine: engine)
    pages.append(record)
    // At most three pages stay alive; the oldest goes.
    while pages.count > 3 {
      dropPage(pages.removeFirst())
    }
    pageRecords[tab] = pages
    shownPages[tab] = pages.count - 1
    hoveredLinks[tab] = nil
    selections[tab] = nil
    switch engine {
    case .chromium: makeContents(tab, page: record.id, context).loadURL(url)
    case .webkit: makeWebKitPage(tab, page: record.id, profile: profile).load(request)
    }
    if muted {
      page(tab)?.isMuted = true
    }
    reportShown(tab)
  }

  // The shown page's URL again, as a page of `engine`.
  func reopen(_ tab: UUID, in engine: PageEngineKind) async {
    guard let url = page(tab)?.url else { return }
    await switchEngine(tab, to: engine, request: URLRequest(url: url))
  }

  func webKitPageDidUpdate(_ page: WebKitPage) {
    guard let tab = shownTab(of: page) else { return }
    if loadProgress[tab] != page.loadProgress {
      loadProgress[tab] = page.loadProgress
    }
    report(tab, page)
  }

  func webContents(_ contents: ECWebContents, didCommitNavigationIsHistory isHistory: Bool) {
    pageDidCommit(contents, url: contents.url, isNewNavigation: !isHistory)
  }

  // A modified click on a link or form of a WebKit page opens elsewhere, as Chromium's dispositions do; true when it
  // does.
  func opensElsewhere(
    _ tab: UUID, _ url: URL, modifierFlags: NSEvent.ModifierFlags, buttonNumber: Int, from view: NSView
  ) -> Bool {
    let command = modifierFlags.contains(.command) || buttonNumber == 2
    let shift = modifierFlags.contains(.shift)
    guard command || shift else { return false }
    let disposition: ECWindowOpenDisposition = command ? (shift ? .newForegroundTab : .newBackgroundTab) : .newWindow
    requestNewWindow(tab, url, disposition: disposition, modifierFlags: modifierFlags, from: view)
    return true
  }

  // A script's popup: a WebKit page in a tab of its own under the tab's id, reported at once so the tab is never
  // saved as Chromium, for the opener's space to adopt.
  func adoptPopup(from opener: UUID, url: URL, configuration: WKWebViewConfiguration) -> WKWebView? {
    guard let profile = tabProfiles[opener] else { return nil }
    let tab = UUID()
    register(tab, profile, incognitoTabs.contains(opener), pages: [PageRecord(id: tab, engine: .webkit)], shown: 0)
    let page = makeWebKitPage(tab, page: tab, profile: profile, configuration: configuration)
    Self.continuation.yield(.adoptRequested(tab: tab, opener: opener, url: url))
    report(tab, page)
    return page.webView
  }

  func webKitPage(_ page: WebKitPage, hovered url: URL?) {
    guard let tab = shownTab(of: page), hoveredLinks[tab] != url else { return }
    hoveredLinks[tab] = url
  }

  func webKitPage(_ page: WebKitPage, selected text: String) {
    guard let tab = shownTab(of: page) else { return }
    let selection = text.isEmpty ? nil : text
    if selections[tab] != selection {
      selections[tab] = selection
    }
  }

  // An alert, confirm or prompt, shown as a dialog over the dimmed page.
  func webKitPage(
    _ page: WebKitPage, runDialog type: ECJavaScriptDialogType, message: String, defaultText: String,
    from origin: WKSecurityOrigin, completion: @escaping (Bool, String) -> Void
  ) {
    if defers(page, {
      self.webKitPage(page, runDialog: type, message: message, defaultText: defaultText, from: origin, completion: completion)
    }) { return }
    guard let tab = tab(of: page) else { return completion(false, "") }
    let host = origin.host.isEmpty ? "This page" : origin.port == 0 ? origin.host : "\(origin.host):\(origin.port)"
    dialogs[tab] = PageDialog(type: type, title: "\(host) says", message: message, defaultText: defaultText) {
      [weak self] accepted, text in
      self?.dialogs[tab] = nil
      completion(accepted, text)
    }
  }

  func webKitPage(
    _ page: WebKitPage, chooseFilesAllowingMultiple multiple: Bool, directories: Bool,
    completion: @escaping ([URL]?) -> Void
  ) {
    if defers(page, {
      self.webKitPage(page, chooseFilesAllowingMultiple: multiple, directories: directories, completion: completion)
    }) { return }
    guard let tab = tab(of: page) else { return completion(nil) }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = directories
    panel.allowsMultipleSelection = multiple
    present(panel, for: tab, { panel.beginSheetModal(for: $0, completionHandler: $1) }) {
      completion($0 == .OK ? panel.urls : nil)
    }
  }

  // An HTTP Basic or Digest challenge: a name and password for the server, nil when cancelled.
  func webKitPage(
    _ page: WebKitPage, askCredentialFor space: URLProtectionSpace, completion: @escaping (URLCredential?) -> Void
  ) {
    if defers(page, { self.webKitPage(page, askCredentialFor: space, completion: completion) }) { return }
    guard let tab = tab(of: page) else { return completion(nil) }
    let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 22))
    name.placeholderString = "Name"
    let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
    password.placeholderString = "Password"
    let fields = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
    fields.addSubview(name)
    fields.addSubview(password)
    let alert = NSAlert()
    alert.messageText = "Log in to \(space.host)"
    alert.accessoryView = fields
    alert.addButton(withTitle: "Log In")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = name
    present(alert.window, for: tab, { alert.beginSheetModal(for: $0, completionHandler: $1) }) {
      completion(
        $0 == .alertFirstButtonReturn
          ? URLCredential(user: name.stringValue, password: password.stringValue, persistence: .forSession) : nil)
    }
  }
}
