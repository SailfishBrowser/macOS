import AppKit
import ComposableArchitecture
@preconcurrency import EngineCore

@MainActor @Observable
final class Engine: NSObject, @preconcurrency ECWebContentsDelegate {
  static let shared = Engine()
  nonisolated static let userDataDir = URL.dataDirectory.appending(path: "Engine").path
  nonisolated static let (events, continuation) = AsyncStream.makeStream(of: WebEngineEvent.self)
  private(set) var contexts: [UUID: ECBrowserContext] = [:]
  // Each tab's pages, oldest first, and the index of the one it shows.
  var pageRecords: [UUID: [PageRecord]] = [:]
  var shownPages: [UUID: Int] = [:]
  // The live pages by page id; a page behind the shown one has none until Back or Forward reaches it.
  var livePages: [UUID: any TabPage] = [:]
  // The tab and page id of each live page.
  @ObservationIgnored var owners: [ObjectIdentifier: (tab: UUID, page: UUID)] = [:]
  // Each tab's shown page when Chromium renders it; extension windows see only these.
  var tabs: [UUID: ECWebContents] {
    pageRecords.keys.reduce(into: [:]) { tabs, tab in tabs[tab] = contents(tab) }
  }
  // Changes with extensions and their actions, so views reading them update.
  var extensionsRevision = 0
  // Each tab's unanswered permission request, shown as a popover on the URL pill.
  var permissionRequests: [UUID: PermissionRequest] = [:]
  // Each tab's open JavaScript dialog, shown over its page.
  var dialogs: [UUID: PageDialog] = [:]
  // Each tab's selected text, for the URL pill's Share Quote.
  var selections: [UUID: String] = [:]
  // The link under the pointer in each tab, shown in a status bubble.
  var hoveredLinks: [UUID: URL] = [:]
  // Tabs whose page has an article, and the article of each tab showing Reader View.
  var readerable: Set<UUID> = []
  var readers: [UUID: ReaderArticle] = [:]
  // How far each loading tab's page has loaded, 0 to 1, shown by the load dash above the page card.
  var loadProgress: [UUID: Double] = [:]
  // Each recently shown tab's page as it last looked, for the tab switcher's cards; the newest last.
  var thumbnails: [UUID: NSImage] = [:]
  @ObservationIgnored private var thumbnailOrder: [UUID] = []
  static let thumbnailCount = 10
  // Tabs of incognito contexts and of Little Sailfish windows, whose link menus leave out what they cannot open.
  @ObservationIgnored var incognitoTabs: Set<UUID> = []
  @ObservationIgnored var littleSailfishTabs: Set<UUID> = []
  // Sheets shown for each tab's page, dismissed when the tab closes.
  @ObservationIgnored var sheets: [UUID: [NSWindow]] = [:]
  // Sheets and requests waiting for their page to be shown, by page id, run again when it is (or closes).
  @ObservationIgnored var pendingSheets: [UUID: [@MainActor () -> Void]] = [:]
  // Contexts reporting downloads, kept so that their indexes identify their downloads.
  @ObservationIgnored var downloadContexts: [ECBrowserContext] = []
  @ObservationIgnored var downloadProfiles: [ECBrowserContext: UUID] = [:]
  // Set when quitting closes every page.
  @ObservationIgnored var isClosed = false
  // Each space as a window to its context's extensions (chrome.windows), by space.
  @ObservationIgnored var windows: [UUID: ECWindow] = [:]
  // Each tab's last reported page; Chromium reports several times per load, mostly without change.
  @ObservationIgnored var lastPages: [UUID: WebPage] = [:]
  @ObservationIgnored weak var windowDelegate: (any ECWindowDelegate)?
  // The context of each tab's web contents, released before their context closes, and the tab's profile.
  @ObservationIgnored var tabContexts: [UUID: ECBrowserContext] = [:]
  @ObservationIgnored var tabProfiles: [UUID: UUID] = [:]
  // The engine and site each tab was last switched to, held while its shown page stays on that site.
  @ObservationIgnored var choices: [UUID: EngineChoice] = [:]
  // When each tab's last search was asked for: the effects that ask arrive in no fixed order.
  @ObservationIgnored var findRequests: [UUID: ContinuousClock.Instant] = [:]
  // Each page's saved history by page id, given to its next page: Chromium's and WebKit's.
  nonisolated static let sessions = SessionStore(directory: URL.dataDirectory.appending(path: "Sessions"))
  nonisolated static let webKitSessions = SessionStore(directory: URL.dataDirectory.appending(path: "WebKitSessions"))
  // Pages that got their saved history and have not loaded yet, and those whose load of it has not committed.
  @ObservationIgnored var restoredPages: Set<UUID> = []
  @ObservationIgnored var restoringPages: Set<UUID> = []

  // Keeps the page as it looks now, as Chrome does for a tab about to be hidden, scaled to the switcher's card.
  func captureThumbnail(_ tab: UUID) {
    guard let page = self.page(tab), !littleSailfishTabs.contains(tab) else { return }
    page.snapshot { [weak self] image in
      guard let image else { return }
      Task { @MainActor in
        guard let self, self.page(tab) != nil else { return }
        self.thumbnails[tab] = image.scaled(toWidth: TabSwitcher.thumbnailSize.width * 2)
        self.thumbnailOrder.removeAll { $0 == tab }
        self.thumbnailOrder.append(tab)
        while self.thumbnailOrder.count > Self.thumbnailCount {
          self.thumbnails[self.thumbnailOrder.removeFirst()] = nil
        }
      }
    }
  }

  // The tab of this view's page, live and shown or not, as it looks now.
  func captureThumbnail(of view: NSView) {
    livePages.first { $0.value.view === view }.flatMap { tab(of: $0.value) }.map { captureThumbnail($0) }
  }

  func view(_ tab: UUID) -> NSView? {
    if let page = shownRecord(tab)?.id, let pending = pendingSheets.removeValue(forKey: page) {
      DispatchQueue.main.async { pending.forEach { $0() } }
    }
    return page(tab)?.view
  }

  // A tab shown again at the page its saved history ends on loads that entry, keeping the history (a restored WebKit
  // page is already loading it); any other page is a new navigation on top of it, in the engine the URL opens in.
  func load(_ tab: UUID, _ url: URL) async {
    guard let record = shownRecord(tab), let page = page(tab) else { return }
    let current = (page as? WebKitPage).map(\.committedURL) ?? page.url
    if restoredPages.remove(record.id) != nil, let current, current.isSamePage(as: url) {
      (page as? ECWebContents)?.loadIfNeeded()
      return
    }
    restoringPages.remove(record.id)
    @Shared(.siteEngines) var siteEngines
    let engine = pageEngine(for: url, from: record.engine, choice: choices[tab], cause: .typed, siteEngines)
    guard engine == record.engine else {
      return await switchEngine(tab, to: engine, request: URLRequest(url: url))
    }
    switch record.engine {
    case .chromium: contents(tab)?.loadURL(url)
    case .webkit: (page as? WebKitPage)?.load(URLRequest(url: url))
    }
  }

  func loadedContext(_ profile: UUID, _ incognito: Bool) -> ECBrowserContext {
    let context = incognito ? contexts[profile]!.offTheRecord : contexts[profile]!
    if !downloadContexts.contains(context) {
      context.downloadDelegate = self
      context.extensionsDelegate = self
      downloadContexts.append(context)
      downloadProfiles[context] = profile
      context.downloads.forEach { browserContext(context, downloadDidUpdate: $0) }
    }
    return context
  }

  func context(for space: Space) async -> ECBrowserContext {
    _ = await context(space.profileID)
    return loadedContext(space.profileID, space.isIncognito)
  }

  func syncWindow(_ space: Space, tabs shown: [Tab], focused: Bool, peeksLinksToOtherSites: Bool) {
    let contents = shown.compactMap { self.contents($0.id) }
    if windows[space.id] == nil, !contents.isEmpty {
      let window = ECWindow(browserContext: loadedContext(space.profileID, space.isIncognito))
      window.delegate = windowDelegate
      windows[space.id] = window
    }
    guard let window = windows[space.id] else { return }
    window.tabs = contents
    // Links to other sites open from favorites and pinned tabs in Peek, unless Settings > Links turns it off.
    for tab in shown {
      self.contents(tab.id)?.opensLinksToOtherSitesInNewWindow = peeksLinksToOtherSites && tab.placement != .unpinned
    }
    window.activeTab = shown.first { $0.id == space.selectedTabID }.flatMap { self.contents($0.id) }
    if window.isFocused != focused {
      window.isFocused = focused
    }
  }

  // A Little Sailfish's page as a window of its own to the context's extensions, which the PDF viewer is one of:
  // its tab had none, and the viewer left the page blank.
  func syncLittleWindow(_ id: UUID, profile: UUID, tab: UUID) {
    guard let contents = self.contents(tab) else { return }
    if windows[id] == nil {
      let window = ECWindow(browserContext: loadedContext(profile, false))
      window.delegate = windowDelegate
      windows[id] = window
    }
    guard let window = windows[id] else { return }
    window.tabs = [contents]
    window.activeTab = contents
    if !window.isFocused {
      window.isFocused = true
    }
  }

  func closeWindows(except spaces: Set<UUID>) {
    for (space, window) in windows where !spaces.contains(space) {
      window.close()
      windows[space] = nil
    }
  }

  func perform(_ tab: UUID, _ operation: (ECWebContents) -> Void) {
    contents(tab).map(operation)
  }

  func zoom(_ tab: UUID, _ step: ZoomStep) -> Int? {
    guard let contents = self.contents(tab) else { return nil }
    switch step {
    case .in: contents.zoomIn()
    case .out: contents.zoomOut()
    case .reset: contents.resetZoom()
    }
    return contents.zoomPercent
  }

  // Runs a search asked for at `requested` unless a later one already ran.
  func find(_ tab: UUID, _ requested: ContinuousClock.Instant, _ operation: (ECWebContents) -> Void) {
    if let last = findRequests[tab], requested < last { return }
    findRequests[tab] = requested
    perform(tab, operation)
  }

  func close(_ tab: UUID) {
    close(tab, keepingHistory: true)
  }

  // Closes the tab's pages and forgets their histories, for a pinned tab reset to its pinned URL.
  func discard(_ tab: UUID) {
    let pages = pageRecords[tab] ?? []
    close(tab, keepingHistory: false)
    Self.sessions.forget(tab)
    for page in pages {
      Self.store(page.engine).forget(page.id)
    }
  }

  private func close(_ tab: UUID, keepingHistory: Bool) {
    thumbnails[tab] = nil
    thumbnailOrder.removeAll { $0 == tab }
    release(tab, keepingHistory: keepingHistory).forEach { $0.close() }
  }

  // Closes every tab before the engine destroys their web contents at quit.
  func closeAll() {
    isClosed = true
    for tab in Array(pageRecords.keys) {
      release(tab, keepingHistory: true).forEach { $0.close() }
    }
  }

  func closeIncognito(_ profile: UUID) {
    guard let context = contexts[profile]?.offTheRecord else { return }
    Autocomplete.forget(context)
    closeTabs(of: context)
    context.close()
  }

  // Closes the profile's context, then has the engine delete its data.
  func deleteProfile(_ profile: UUID) {
    if let context = contexts.removeValue(forKey: profile) {
      Autocomplete.forget(context)
      closeTabs(of: context)
      context.close()
    }
    ECBrowserContext.deleteProfile(atPath: Self.userDataDir + "/" + profile.uuidString)
  }

  private func closeTabs(of context: ECBrowserContext) {
    for (tab, owner) in tabContexts where owner === context {
      release(tab, keepingHistory: true).forEach { $0.close() }
    }
  }

  func context(_ profile: UUID) async -> ECBrowserContext {
    if let context = contexts[profile] { return context }
    let context = await withCheckedContinuation { continuation in
      ECBrowserContext.load(withPath: Self.userDataDir + "/" + profile.uuidString) {
        continuation.resume(returning: $0!)
      }
    }
    contexts[profile] = context
    applyAdBlocking(context)
    return context
  }

  func webContentsDidUpdate(_ contents: ECWebContents) {
    guard let tab = shownTab(of: contents) else { return }
    PictureInPicture.place(contents, of: tab)
    report(tab, contents)
  }

  func webContents(_ contents: ECWebContents, didChangeLoadProgress progress: Double) {
    guard let tab = shownTab(of: contents) else { return }
    loadProgress[tab] = progress
  }

  // Required by the protocol; the engine calls the one with modifier flags instead, so this never runs.
  func webContents(
    _ contents: ECWebContents, requestsNewWindowWith url: URL, disposition: ECWindowOpenDisposition
  ) {
    webContents(contents, requestsNewWindowWith: url, disposition: disposition, modifierFlags: [])
  }

  func webContents(
    _ contents: ECWebContents, requestsNewWindowWith url: URL, disposition: ECWindowOpenDisposition,
    modifierFlags: NSEvent.ModifierFlags
  ) {
    guard let tab = tab(of: contents) else { return }
    requestNewWindow(tab, url, disposition: disposition, modifierFlags: modifierFlags, from: contents.view)
  }

  // ⌘-click or middle click opens a background tab, ⇧⌘-click a tab in front, ⌥⌘-click a Little Sailfish
  // (not from an incognito page), and a ⇧-click, or a link to another site from a pinned tab, opens in Peek.
  func requestNewWindow(
    _ tab: UUID, _ url: URL, disposition: ECWindowOpenDisposition, modifierFlags: NSEvent.ModifierFlags,
    from view: NSView
  ) {
    @Shared(.littleSailfishOnOptionCommandClick) var littleSailfishOnOptionCommandClick
    @Shared(.peeksOnShiftClick) var peeksOnShiftClick
    if littleSailfishOnOptionCommandClick, modifierFlags.isSuperset(of: [.option, .command]), !incognitoTabs.contains(tab) {
      Self.continuation.yield(.littleSailfishRequested(tab: tab, url: url))
      return
    }
    // With Shift-click Peek off in Settings > Links, a ⇧-click opens a tab in front instead.
    guard disposition == .newWindow, peeksOnShiftClick || !modifierFlags.contains(.shift) else {
      Self.continuation.yield(.newWindowRequested(tab: tab, url: url, background: disposition == .newBackgroundTab))
      return
    }
    // Peek grows from the link clicked, so it starts at the pointer, from the page's top left.
    let point = view.window.map { view.convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
    Self.continuation.yield(
      .peekRequested(tab: tab, url: url, at: CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)))
  }

  // The permissions the user allowed or blocked for the site of the tab's page.
  func sitePermissions(_ tab: UUID) -> [String: Bool] {
    contents(tab)?.sitePermissions.mapValues(\.boolValue) ?? [:]
  }

  func setSitePermission(_ tab: UUID, _ key: String, allowed: Bool) {
    contents(tab)?.setSitePermission(key, allowed: allowed)
  }
}

extension WebEngineClient: DependencyKey {
  static let liveValue = Self(
    create: { await Engine.shared.create($0, $1, $2, pages: $3, shown: $4) },
    load: { await Engine.shared.load($0, $1) },
    switchEngine: { await Engine.shared.reopen($0, in: $1) },
    littleWindow: { await Engine.shared.syncLittleWindow($0, profile: $1, tab: $2) },
    goBack: { await Engine.shared.goBack($0) },
    goForward: { await Engine.shared.goForward($0) },
    goToEntry: { tab, entry in await Engine.shared.goToEntry(tab, entry) },
    reload: { await Engine.shared.reload($0) },
    stop: { await Engine.shared.stop($0) },
    setMuted: { tab, muted in await Engine.shared.perform(tab) { $0.isMuted = muted } },
    media: { tab, command in await PictureInPicture.perform(command, on: tab) },
    close: { await Engine.shared.close($0) },
    discard: { await Engine.shared.discard($0) },
    closeIncognito: { await Engine.shared.closeIncognito($0) },
    deleteProfile: { await Engine.shared.deleteProfile($0) },
    find: { tab, string, forward, requested in
      await Engine.shared.find(tab, requested) { $0.find(string, forward: forward) }
    },
    findAsTyped: { tab, string, requested in await Engine.shared.find(tab, requested) { $0.find(string) } },
    stopFinding: { tab, requested in await Engine.shared.find(tab, requested) { $0.stopFinding() } },
    cancelDownload: { await Engine.shared.cancelDownload($0) },
    zoom: { tab, step in await Engine.shared.zoom(tab, step) },
    saveSessions: { await Engine.shared.saveSessions() },
    keepSessions: {
      Engine.sessions.keep($0)
      Engine.webKitSessions.keep($0)
    },
    copySession: { Engine.sessions.copy($0, to: $1) },
    events: { Engine.events }
  )
}
