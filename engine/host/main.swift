import AppKit
import EngineCore

final class Tab {
  let contents: ECWebContents
  let window: NSWindow
  let incognito: Bool
  var snapshotted = false

  init(contents: ECWebContents, window: NSWindow, incognito: Bool) {
    self.contents = contents
    self.window = window
    self.incognito = incognito
  }
}

final class Host: NSObject, ECWebContentsDelegate, ECDownloadDelegate, NSWindowDelegate {
  let profilePath: String
  let snapshotDir: String?
  var context: ECBrowserContext?
  var tabs: [Tab] = []
  var testTab: Tab?
  var testStarted = false
  let upload = URL(fileURLWithPath: NSTemporaryDirectory() + "engine-upload.txt")
  var captured = 0
  // URLs opened at launch arrive before the profile has loaded.
  var pendingURLs: [URL] = []

  init(profilePath: String, snapshotDir: String?) {
    self.profilePath = profilePath
    self.snapshotDir = snapshotDir
  }

  func run() {
    NSApp.mainMenu = mainMenu()
    ECBrowserContext.load(withPath: profilePath) { context in
      self.context = context!
      context!.downloadDelegate = self
      context!.offTheRecord.downloadDelegate = self
      self.open(URL(string: "https://en.wikipedia.org")!, in: context!, incognito: false)
      self.open(URL(string: "https://github.com")!, in: context!.offTheRecord, incognito: true)
      self.testTab = self.open(URL(string: "https://example.com")!, in: context!, incognito: false)
      // Captured by the test, not on its favicon.
      self.testTab!.snapshotted = true
      self.openURLs(self.pendingURLs)
    }
  }

  // Drives the page UI the shell presents, answering every request itself.
  // The page logs what it saw, and the window is captured at the end.
  func runTest(_ tab: Tab) {
    try! "upload".write(to: upload, atomically: true, encoding: .utf8)
    let c = tab.contents
    let steps: [() -> Void] = [
      {
        self.js(c, """
          document.body.innerHTML = '<input id=f type=file multiple accept="image/*,.txt">\
          <a id=a href="https://example.com/linked" style="position:fixed;left:0;top:100px;font-size:40px">Engine link</a>\
          <pre id=out style="position:fixed;left:0;top:200px;font-size:18px;text-align:left">engine engine\\n</pre>';
          window.log = s => out.textContent += s + '\\n';
          f.onchange = () => log('files ' + [...f.files].map(x => x.name))
          """)
      },
      { self.js(c, "log('alert ' + alert('hello')); log('confirm ' + confirm('sure?')); log('prompt ' + prompt('name?', 'default'))") },
      { self.js(c, "Notification.requestPermission().then(p => log('notifications ' + p))") },
      { self.js(c, "Notification.requestPermission().then(p => log('notifications again ' + p))") },
      { c.find("engine", forward: true) },
      { c.find("engine", forward: true) },
      { c.stopFinding(); self.js(c, "getSelection().selectAllChildren(a)") },
      { self.rightClick(tab.window, x: 50, y: 125) },
      {
        print("pasteboard \(NSPasteboard.general.string(forType: .string) ?? "")")
        // The right click activated the page, which a file chooser needs.
        self.js(c, "f.click()")
      },
      {
        self.js(c, "const d = document.createElement('a'); d.href = URL.createObjectURL(new Blob(['engine'])); d.download = 'engine-download.txt'; d.click()")
        // Incognito downloads save without asking too.
        self.js(self.tabs[1].contents, "const d = document.createElement('a'); d.href = URL.createObjectURL(new Blob(['engine'])); d.download = 'engine-incognito.txt'; d.click()")
      },
      { self.js(c, "onbeforeunload = e => e.preventDefault()") },
      { c.loadURL(URL(string: "https://example.org")!) },
      { self.js(c, "log('stayed on ' + location.host)") },
      {
        if let dir = self.snapshotDir { self.snapshot(tab.window, to: "\(dir)/content-ui.png") }
      },
    ]
    for (i, step) in steps.enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(i)) {
        print("test step \(i)")
        step()
      }
    }
  }

  // Runs `code` in the page, as a bookmarklet does.
  func js(_ contents: ECWebContents, _ code: String) {
    contents.loadURL(URL(string: "javascript:" + (code + ";void 0").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!)
  }

  // Posts a right click at (x, y) from the window's top left. A left click
  // would only activate the app, which a remote Mac's locked screen prevents.
  func rightClick(_ window: NSWindow, x: CGFloat, y: CGFloat) {
    let location = NSPoint(x: x, y: window.contentView!.bounds.height - y)
    for type: NSEvent.EventType in [.rightMouseDown, .rightMouseUp] {
      NSApp.postEvent(
        NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!,
        atStart: false)
    }
  }

  func mainMenu() -> NSMenu {
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r").target = self
    appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let appItem = NSMenuItem()
    appItem.submenu = appMenu
    let menu = NSMenu()
    menu.addItem(appItem)
    return menu
  }

  @objc func reload() {
    print("menu reload")
    tabs.first { $0.window.isKeyWindow }?.contents.reload()
  }

  @discardableResult
  func open(_ url: URL, in context: ECBrowserContext, incognito: Bool) -> Tab {
    let contents = ECWebContents(browserContext: context)
    contents.delegate = self
    let window = NSWindow(
      contentRect: NSRect(x: 100 + 60 * tabs.count, y: 100, width: 1000, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.delegate = self
    contents.view.frame = window.contentView!.bounds
    contents.view.autoresizingMask = [.width, .height]
    window.contentView!.addSubview(contents.view)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    let tab = Tab(contents: contents, window: window, incognito: incognito)
    tabs.append(tab)
    contents.loadURL(url)
    return tab
  }

  func openURLs(_ urls: [URL]) {
    print("open urls \(urls)")
    guard let context else {
      pendingURLs += urls
      return
    }
    urls.forEach { open($0, in: context, incognito: false) }
  }

  func reopen() {
    print("reopen tabs=\(tabs.count)")
    if tabs.isEmpty {
      open(URL(string: "https://example.com")!, in: context!, incognito: false)
    }
  }

  func windowWillClose(_ notification: Notification) {
    let tab = tabs.first { $0.window === notification.object as? NSWindow }!
    tabs.removeAll { $0 === tab }
    // Closing the incognito context closes its web contents and discards it.
    if tab.incognito {
      context!.offTheRecord.close()
    } else {
      tab.contents.close()
    }
  }

  func webContentsDidUpdate(_ contents: ECWebContents) {
    let tab = tabs.first { $0.contents === contents }!
    tab.window.title = (tab.incognito ? "Incognito: " : "") + contents.title
    tab.window.representedURL = contents.url
    tab.window.standardWindowButton(.documentIconButton)?.image = contents.favicon
    print("update url=\(contents.url?.absoluteString ?? "") title=\(contents.title) loading=\(contents.isLoading) favicon=\(contents.favicon?.size ?? .zero)")
    if let dir = snapshotDir, !tab.snapshotted, !contents.isLoading, contents.favicon != nil {
      tab.snapshotted = true
      let path = "\(dir)/\(tab.incognito ? "incognito" : "regular").png"
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.snapshot(tab.window, to: path) }
    }
    if tab === testTab, !testStarted, !contents.isLoading {
      testStarted = true
      runTest(tab)
    }
  }

  // Captures this process's own window, which needs no Screen Recording
  // permission. Once every tab is captured, closes them and quits.
  func snapshot(_ window: NSWindow, to path: String) {
    let image = CGWindowListCreateImage(
      .null, .optionIncludingWindow, CGWindowID(window.windowNumber), .boundsIgnoreFraming)!
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
    print("snapshot \(path)")
    captured += 1
    if captured == tabs.count {
      tabs.forEach { $0.window.close() }
      context!.close()
      print("closed")
      NSApp.terminate(nil)
    }
  }

  func webContents(_ contents: ECWebContents, requestsNewWindowWith url: URL, disposition: ECWindowOpenDisposition) {
    contents.loadURL(url)
  }

  func webContents(
    _ contents: ECWebContents, requestsPermissions permissions: [String], forOrigin origin: URL,
    completionHandler: @escaping (Bool) -> Void
  ) {
    print("permissions \(permissions) for \(origin)")
    completionHandler(true)
  }

  // Accepts alerts, confirms and prompts, and stays on the page.
  func webContents(
    _ contents: ECWebContents, run type: ECJavaScriptDialogType, message: String,
    defaultText: String, completionHandler: @escaping (Bool, String) -> Void
  ) {
    print("dialog \(type.rawValue) \(message) \(defaultText)")
    completionHandler(type != .beforeUnload, "answer")
  }

  func webContents(
    _ contents: ECWebContents, runFileChooserWithAcceptTypes acceptTypes: [String], allowsMultiple: Bool,
    directory: Bool, completionHandler: @escaping ([URL]?) -> Void
  ) {
    print("file chooser \(acceptTypes) multiple=\(allowsMultiple) directory=\(directory)")
    completionHandler([upload])
  }

  func webContents(_ contents: ECWebContents, didFindMatches matches: Int, activeMatch: Int) {
    print("find \(activeMatch)/\(matches)")
  }

  // Copies the selection, as a Copy menu item would.
  func webContents(_ contents: ECWebContents, showContextMenu menu: ECContextMenu) {
    print("context menu link=\(menu.linkURL?.absoluteString ?? "") image=\(menu.imageURL?.absoluteString ?? "") selection=\(menu.selectionText) editable=\(menu.isEditable)")
    contents.copy(nil)
  }

  func browserContext(_ context: ECBrowserContext, downloadDidUpdate download: ECDownload) {
    print("download \(download.identifier) \(download.fileURL?.path ?? "") \(download.receivedBytes)/\(download.totalBytes) state=\(download.state.rawValue)")
  }
}

// With --extensions: installs Dark Reader (content scripts and a popup that
// reads the active tab) and OneTab (chrome.tabs query, create and remove)
// from the Chrome Web Store into one shell window, runs both actions, then
// disables and enables Dark Reader, uninstalls OneTab and closes a tab
// with window.close().
final class ExtensionsHost: NSObject, ECWebContentsDelegate, ECWindowDelegate, ECExtensionsDelegate,
  ECExtensionPopupDelegate
{
  static let darkReader = "eimadpbcbfnmbkopoojfekhnkhdbieeh"
  static let oneTab = "chphlpgkkbolifaimnlloiipkdnihall"
  let profilePath: String
  let snapshotDir: String
  var context: ECBrowserContext!
  var window: ECWindow!
  lazy var nsWindow = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
  var popup: ECExtensionPopup?
  lazy var popupWindow = NSWindow(
    contentRect: NSRect(x: 1150, y: 100, width: 25, height: 25), styleMask: [.titled],
    backing: .buffered, defer: false)

  init(profilePath: String, snapshotDir: String) {
    self.profilePath = profilePath
    self.snapshotDir = snapshotDir
  }

  func run() {
    NSApp.mainMenu = NSMenu()
    ECBrowserContext.load(withPath: profilePath) { context in
      self.context = context!
      context!.extensionsDelegate = self
      self.window = ECWindow(browserContext: context!)
      self.window.delegate = self
      self.nsWindow.isReleasedWhenClosed = false
      self.nsWindow.makeKeyAndOrderFront(nil)
      _ = self.window(self.window, openTabWith: URL(string: "https://example.com")!, active: true)
      self.window.isFocused = true
      self.after(3) { self.install(Self.darkReader) { self.install(Self.oneTab) { self.test() } } }
    }
  }

  var tab: ECWebContents { window.activeTab! }

  func after(_ seconds: Double, _ block: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
  }

  func installed(_ id: String) -> Bool { context.extensions.contains { $0.identifier == id } }

  // Opens the store page and presses Add to Chrome.
  func install(_ id: String, then: @escaping () -> Void) {
    if installed(id) { return then() }
    tab.loadURL(URL(string: "https://chromewebstore.google.com/detail/" + id)!)
    after(10) {
      self.js("[...document.querySelectorAll('button')].find(b => /Add to Chrome/.test(b.textContent)).click()")
      self.wait(until: { self.installed(id) }, then: then)
    }
  }

  func wait(until done: @escaping () -> Bool, then: @escaping () -> Void) {
    if done() { return then() }
    after(1) { self.wait(until: done, then: then) }
  }

  func js(_ code: String) {
    tab.loadURL(URL(string: "javascript:" + (code + ";void 0").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!)
  }

  func test() {
    for e in context.extensions {
      let action = context.action(forExtension: e.identifier, in: tab)
      print("extension \(e.identifier) \(e.name) enabled=\(e.isEnabled) icon=\(e.icon?.size ?? .zero) action=\(action?.title ?? "-") badge=\(action?.badgeText ?? "") actionIcon=\(action?.icon?.size ?? .zero) actionEnabled=\(action?.isEnabled ?? false)")
    }
    tab.loadURL(URL(string: "https://example.com")!)
    _ = window(window, openTabWith: URL(string: "https://example.org")!, active: false)
    after(5) {
      self.js("document.title = 'darkreader ' + !!document.querySelector('style.darkreader')")
    }
    after(7) {
      self.popup = self.context.runAction(forExtension: Self.darkReader, in: self.tab)
      print("popup \(self.popup != nil)")
      self.popup?.delegate = self
      self.popup!.view.frame = self.popupWindow.contentView!.bounds
      self.popupWindow.contentView!.addSubview(self.popup!.view)
      self.popupWindow.orderFront(nil)
    }
    after(15) {
      self.snapshot(self.popupWindow, "popup")
      self.snapshot(self.nsWindow, "darkreader")
      self.popup?.close()
      print("run onetab \(self.context.runAction(forExtension: Self.oneTab, in: self.tab) == nil)")
    }
    after(25) {
      print("tabs \(self.window.tabs.map { $0.url?.absoluteString ?? "" })")
      self.snapshot(self.nsWindow, "onetab")
      self.context.setEnabled(false, forExtension: Self.darkReader)
      self.context.uninstallExtension(Self.oneTab)
    }
    after(27) {
      self.context.setEnabled(true, forExtension: Self.darkReader)
      _ = self.window(self.window, openTabWith: URL(string: "https://example.net")!, active: true)
    }
    // A tab with one page may close itself.
    after(31) { self.js("window.close()") }
    after(33) {
      print("tabs \(self.window.tabs.map { $0.url?.absoluteString ?? "" })")
      NSApp.terminate(nil)
    }
  }

  func webContentsDidRequestClose(_ contents: ECWebContents) {
    print("close requested \(contents.url?.absoluteString ?? "")")
    window(window, closeTab: contents)
  }


  func snapshot(_ window: NSWindow, _ name: String) {
    let image = CGWindowListCreateImage(
      .null, .optionIncludingWindow, CGWindowID(window.windowNumber), .boundsIgnoreFraming)!
    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(snapshotDir)/\(name).png"))
    print("snapshot \(name)")
  }

  func show(_ contents: ECWebContents) {
    nsWindow.contentView!.subviews.forEach { $0.removeFromSuperview() }
    contents.view.frame = nsWindow.contentView!.bounds
    contents.view.autoresizingMask = [.width, .height]
    nsWindow.contentView!.addSubview(contents.view)
  }

  func window(_ window: ECWindow, openTabWith url: URL, active: Bool) -> ECWebContents? {
    print("open tab \(url) active=\(active)")
    let contents = ECWebContents(browserContext: context)
    contents.delegate = self
    window.tabs = window.tabs + [contents]
    contents.loadURL(url)
    if active { self.window(window, activateTab: contents) }
    return contents
  }

  func window(_ window: ECWindow, activateTab contents: ECWebContents) {
    print("activate tab \(contents.url?.absoluteString ?? "")")
    window.activeTab = contents
    show(contents)
  }

  func window(_ window: ECWindow, closeTab contents: ECWebContents) {
    print("close tab \(contents.url?.absoluteString ?? "")")
    contents.close()
    if window.activeTab == nil, let next = window.tabs.last { self.window(window, activateTab: next) }
  }

  func browserContextExtensionsDidChange(_ context: ECBrowserContext) {
    print("extensions \(context.extensions.map { "\($0.name) \($0.isEnabled) \($0.icon?.size ?? .zero)" })")
  }

  func browserContext(
    _ context: ECBrowserContext, actionDidChangeForExtension identifier: String, webContents contents: ECWebContents?
  ) {
    print("action changed \(identifier) \(contents?.url?.absoluteString ?? "all tabs")")
  }

  func webContents(
    _ contents: ECWebContents, requestsInstallOfExtensionNamed name: String, icon: NSImage?,
    permissions: [String], completionHandler: @escaping (Bool) -> Void
  ) {
    print("install \(name) icon=\(icon?.size ?? .zero) permissions=\(permissions)")
    completionHandler(true)
  }

  func extensionPopupDidResize(_ popup: ECExtensionPopup) {
    print("popup size \(popup.size)")
    popupWindow.setContentSize(popup.size)
    popup.view.frame = NSRect(origin: .zero, size: popup.size)
  }

  func extensionPopupDidClose(_ popup: ECExtensionPopup) {
    print("popup closed")
  }

  func webContentsDidUpdate(_ contents: ECWebContents) {
    print("update \(contents.url?.absoluteString ?? "") title=\(contents.title) loading=\(contents.isLoading)")
  }

  func webContents(_ contents: ECWebContents, requestsNewWindowWith url: URL, disposition: ECWindowOpenDisposition) {
    _ = window(window, openTabWith: url, active: true)
  }
}

// With --autocomplete: visits a few pages and searches Wikipedia, then prints
// the matches for "wik", "bing.com" (a search engine's site) and "rust"
// searched with Bing and Wikipedia in keyword mode, opens the first one as the
// shell would, saves its favicon, and prints the matches for a search.
final class AutocompleteHost: NSObject, ECWebContentsDelegate, ECAutocompleteDelegate {
  let profilePath: String
  let snapshotDir: String
  var context: ECBrowserContext!
  var contents: ECWebContents!
  var autocomplete: ECAutocomplete!
  var queries: [(String, String?)] = [("wik", nil), ("bing.com", nil), ("rust", "bing.com"), ("rust", "wikipedia.org"), ("rust language", nil)]
  var query = ""

  init(profilePath: String, snapshotDir: String) {
    self.profilePath = profilePath
    self.snapshotDir = snapshotDir
  }

  func run() {
    NSApp.mainMenu = NSMenu()
    ECBrowserContext.load(withPath: profilePath) { context in
      self.context = context!
      self.contents = ECWebContents(browserContext: context!)
      self.contents.delegate = self
      self.autocomplete = ECAutocomplete(browserContext: context!)
      self.autocomplete.delegate = self
      // Searching Wikipedia makes Chrome add it as a site search.
      let search = "javascript:searchInput.value='Rust';document.getElementById('search-form').requestSubmit();void 0"
        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
      let pages = ["https://www.wikipedia.org", search, "https://example.com", "https://www.rust-lang.org"]
      for (i, page) in pages.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5 * Double(i)) { self.contents.loadURL(URL(string: page)!) }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 25) { self.next() }
    }
  }

  func next() {
    guard !queries.isEmpty else { return NSApp.terminate(nil) }
    let (text, keyword) = queries.removeFirst()
    query = text
    print("autocomplete \(text) keyword=\(keyword ?? "")")
    autocomplete.start(withText: text, keyword: keyword)
  }

  func autocomplete(_ autocomplete: ECAutocomplete, didUpdateMatches matches: [ECAutocompleteMatch], done: Bool) {
    print("matches done=\(done)")
    for m in matches {
      print("  type=\(m.type.rawValue) default=\(m.allowedToBeDefault) \(m.contents) | \(m.matchDescription) -> \(m.destinationURL) inline=\(m.inlineAutocompletion) keyword=\(m.associatedKeyword ?? "") \(m.associatedKeywordName ?? "")")
    }
    guard done else { return }
    if let first = matches.first {
      autocomplete.didSelect(first)
      contents.loadURL(first.destinationURL)
      let path = "\(snapshotDir)/favicon-\(query).png"
      context.favicon(forPageURL: first.destinationURL) { favicon in
        print("favicon \(first.destinationURL) \(favicon?.size ?? .zero)")
        guard let favicon else { return }
        let png = NSBitmapImageRep(data: favicon.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: path))
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.next() }
  }

  func webContentsDidUpdate(_ contents: ECWebContents) {}

  func webContents(_ contents: ECWebContents, requestsNewWindowWith url: URL, disposition: ECWindowOpenDisposition) {}
}

setvbuf(stdout, nil, _IOLBF, 0)
let extensionsTest = CommandLine.arguments.contains("--extensions")
let autocompleteTest = CommandLine.arguments.contains("--autocomplete")
let userDataDir =
  NSHomeDirectory() + "/Library/Application Support/EngineHost"
  + (extensionsTest ? "Extensions" : autocompleteTest ? "Autocomplete" : "")
let snapshotFlag = "--snapshot="
let snapshotDir = CommandLine.arguments.first { $0.hasPrefix(snapshotFlag) }
  .map { String($0.dropFirst(snapshotFlag.count)) }
let host = Host(profilePath: userDataDir + "/Default", snapshotDir: snapshotDir)
let extensionsHost = ExtensionsHost(profilePath: userDataDir + "/Default", snapshotDir: snapshotDir ?? "/tmp")
let autocompleteHost = AutocompleteHost(profilePath: userDataDir + "/Default", snapshotDir: snapshotDir ?? "/tmp")
NotificationCenter.default.addObserver(
  forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
) { _ in
  autocompleteTest ? autocompleteHost.run() : extensionsTest ? extensionsHost.run() : host.run()
}
NotificationCenter.default.addObserver(forName: .ECEngineOpenURLs, object: nil, queue: .main) {
  host.openURLs($0.object as! [URL])
}
NotificationCenter.default.addObserver(forName: .ECEngineReopen, object: nil, queue: .main) { _ in
  host.reopen()
}
ECEngine.start(withArguments: CommandLine.arguments + ["--user-data-dir=" + userDataDir])
