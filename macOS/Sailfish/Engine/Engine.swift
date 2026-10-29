import AppKit
import ComposableArchitecture
@preconcurrency import EngineCore

@MainActor @Observable
final class Engine: NSObject, @preconcurrency ECWebContentsDelegate {
  static let shared = Engine()
  nonisolated static let userDataDir = URL.dataDirectory.appending(path: "Engine").path
  nonisolated static let (events, continuation) = AsyncStream.makeStream(of: WebEngineEvent.self)
  private(set) var contexts: [UUID: ECBrowserContext] = [:]
  private(set) var tabs: [UUID: ECWebContents] = [:]
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
  // Sheets waiting for their tab to be shown, run again when it is (or closes).
  @ObservationIgnored var pendingSheets: [UUID: [@MainActor () -> Void]] = [:]
  // Contexts reporting downloads, kept so that their indexes identify their downloads.
  @ObservationIgnored var downloadContexts: [ECBrowserContext] = []
  @ObservationIgnored var downloadProfiles: [ECBrowserContext: UUID] = [:]
  // Set when quitting closes every page.
  @ObservationIgnored private var isClosed = false
  // Each space as a window to its context's extensions (chrome.windows), by space.
  @ObservationIgnored var windows: [UUID: ECWindow] = [:]
  // Each tab's last reported page; Chromium reports several times per load, mostly without change.
  @ObservationIgnored private(set) var lastPages: [UUID: WebPage] = [:]
  @ObservationIgnored weak var windowDelegate: (any ECWindowDelegate)?
  // The context of each tab's web contents, released before their context closes.
  @ObservationIgnored private var tabContexts: [UUID: ECBrowserContext] = [:]
  // When each tab's last search was asked for: the effects that ask arrive in no fixed order.
  @ObservationIgnored private var findRequests: [UUID: ContinuousClock.Instant] = [:]
  // Each tab's saved history, given to its next web contents.
  nonisolated static let sessions = SessionStore(directory: URL.dataDirectory.appending(path: "Sessions"))
  // Tabs whose web contents got their saved history and have not loaded yet.
  @ObservationIgnored private var restoredTabs: Set<UUID> = []

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

  // The page of this view, if it is a tab's, as it looks now.
  func captureThumbnail(of view: NSView) {
    tabs.first { $0.value.view === view }.map { captureThumbnail($0.key) }
  }

  func view(_ tab: UUID) -> NSView? {
    if let pending = pendingSheets.removeValue(forKey: tab) {
      DispatchQueue.main.async { pending.forEach { $0() } }
    }
    return page(tab)?.view
  }

  func create(_ tab: UUID, _ profile: UUID, _ incognito: Bool) async {
    _ = await context(profile)
    // Once quitting has closed every page, none is made.
    guard !isClosed else { return }
    makeContents(tab, profile, incognito)
  }

  // Needs the profile's context loaded. A page the tab still has, such as a closing Peek that undo brings back,
  // is saved and closed first, so the new one starts from its history.
  @discardableResult
  func makeContents(_ tab: UUID, _ profile: UUID, _ incognito: Bool) -> ECWebContents {
    release(tab, keepingHistory: true)?.close()
    let context = loadedContext(profile, incognito)
    let contents = ECWebContents(browserContext: context)
    contents.delegate = self
    tabs[tab] = contents
    tabContexts[tab] = context
    if incognito {
      incognitoTabs.insert(tab)
    }
    if let state = Self.sessions.load(tab), contents.restoreSessionState(state) {
      restoredTabs.insert(tab)
    }
    return contents
  }

  // A tab shown again at the page its saved history ends on loads that entry, keeping the history; any other
  // page is a new navigation on top of it.
  func load(_ tab: UUID, _ url: URL) {
    guard let contents = tabs[tab] else { return }
    if restoredTabs.remove(tab) != nil, let current = contents.url, current.isSamePage(as: url) {
      contents.loadIfNeeded()
    } else {
      contents.loadURL(url)
    }
  }

  func saveSessions() {
    for (tab, contents) in tabs {
      saveSession(tab, contents)
    }
  }

  private func saveSession(_ tab: UUID, _ contents: ECWebContents) {
    if let state = contents.sessionState {
      Self.sessions.save(tab, state, inMemory: incognitoTabs.contains(tab))
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
    let contents = shown.compactMap { tabs[$0.id] }
    if windows[space.id] == nil, !contents.isEmpty {
      let window = ECWindow(browserContext: loadedContext(space.profileID, space.isIncognito))
      window.delegate = windowDelegate
      windows[space.id] = window
    }
    guard let window = windows[space.id] else { return }
    window.tabs = contents
    // Links to other sites open from favorites and pinned tabs in Peek, unless Settings > Links turns it off.
    for tab in shown {
      tabs[tab.id]?.opensLinksToOtherSitesInNewWindow = peeksLinksToOtherSites && tab.placement != .unpinned
    }
    window.activeTab = shown.first { $0.id == space.selectedTabID }.flatMap { tabs[$0.id] }
    if window.isFocused != focused {
      window.isFocused = focused
    }
  }

  // A Little Sailfish's page as a window of its own to the context's extensions, which the PDF viewer is one of:
  // its tab had none, and the viewer left the page blank.
  func syncLittleWindow(_ id: UUID, profile: UUID, tab: UUID) {
    guard let contents = tabs[tab] else { return }
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
    tabs[tab].map(operation)
  }

  func zoom(_ tab: UUID, _ step: ZoomStep) -> Int? {
    guard let contents = tabs[tab] else { return nil }
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

  // Closes the tab's page and forgets its history, for a pinned tab reset to its pinned URL.
  func discard(_ tab: UUID) {
    close(tab, keepingHistory: false)
    Self.sessions.forget(tab)
  }

  private func close(_ tab: UUID, keepingHistory: Bool) {
    thumbnails[tab] = nil
    thumbnailOrder.removeAll { $0 == tab }
    release(tab, keepingHistory: keepingHistory)?.close()
  }

  // Closes every tab before the engine destroys their web contents at quit.
  func closeAll() {
    isClosed = true
    for tab in Array(tabs.keys) {
      release(tab, keepingHistory: true)?.close()
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
      release(tab, keepingHistory: true)?.close()
    }
  }

  // Forgets the tab and detaches from its web contents: a web contents being destroyed reports
  // navigation state changes, which must not reach the shell once it has let the tab go.
  private func release(_ tab: UUID, keepingHistory: Bool) -> ECWebContents? {
    if keepingHistory, let contents = tabs[tab] {
      saveSession(tab, contents)
    }
    restoredTabs.remove(tab)
    for sheet in sheets.removeValue(forKey: tab) ?? [] {
      sheet.sheetParent?.endSheet(sheet, returnCode: .abort)
    }
    permissionRequests.removeValue(forKey: tab)?.answer(false)
    dialogs.removeValue(forKey: tab)?.answer(false, "")
    selections[tab] = nil
    hoveredLinks[tab] = nil
    readerable.remove(tab)
    readers[tab] = nil
    loadProgress[tab] = nil
    incognitoTabs.remove(tab)
    lastPages[tab] = nil
    tabContexts[tab] = nil
    findRequests[tab] = nil
    let contents = tabs.removeValue(forKey: tab)
    contents?.delegate = nil
    pendingSheets.removeValue(forKey: tab)?.forEach { $0() }
    return contents
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
    guard let tab = tab(of: contents) else { return }
    let page = WebPage(
      url: contents.url, title: contents.title, favicon: contents.favicon, isLoading: contents.isLoading,
      canGoBack: contents.canGoBack, canGoForward: contents.canGoForward, isAudible: contents.isAudible,
      isMuted: contents.isMuted, media: contents.media)
    PictureInPicture.place(contents, of: tab)
    let previous = lastPages[tab]
    guard previous != page else { return }
    lastPages[tab] = page
    updateReader(tab, contents, from: previous, to: page)
    Self.continuation.yield(.updated(tab: tab, page: page))
  }

  func webContents(_ contents: ECWebContents, didChangeLoadProgress progress: Double) {
    guard let tab = tab(of: contents) else { return }
    loadProgress[tab] = progress
  }

  // Required by the protocol; the engine calls the one with modifier flags instead, so this never runs.
  func webContents(
    _ contents: ECWebContents, requestsNewWindowWith url: URL, disposition: ECWindowOpenDisposition
  ) {
    webContents(contents, requestsNewWindowWith: url, disposition: disposition, modifierFlags: [])
  }

  // ⌘-click or middle click opens a background tab, ⇧⌘-click a tab in front, ⌥⌘-click a Little Sailfish
  // (not from an incognito page), and a ⇧-click, or a link to another site from a pinned tab, opens in Peek.
  func webContents(
    _ contents: ECWebContents, requestsNewWindowWith url: URL, disposition: ECWindowOpenDisposition,
    modifierFlags: NSEvent.ModifierFlags
  ) {
    guard let tab = tab(of: contents) else { return }
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
    let view = contents.view
    let point = view.window.map { view.convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
    Self.continuation.yield(
      .peekRequested(tab: tab, url: url, at: CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)))
  }

  // The page the tab shows.
  func page(_ tab: UUID) -> (any TabPage)? {
    tabs[tab]
  }

  func backEntries(_ tab: UUID) -> [HistoryEntry] {
    tabs[tab].map { historyEntries($0.backEntries, of: tab) } ?? []
  }

  func forwardEntries(_ tab: UUID) -> [HistoryEntry] {
    tabs[tab].map { historyEntries($0.forwardEntries, of: tab) } ?? []
  }

  private func historyEntries(_ entries: [ECNavigationEntry], of tab: UUID) -> [HistoryEntry] {
    entries.map { HistoryEntry(page: tab, index: $0.index, url: $0.url, title: $0.title) }
  }

  // The entry is looked up again by its index, as the menu's copy may be stale.
  func goToEntry(_ tab: UUID, _ entry: HistoryEntry) async {
    guard let contents = tabs[tab],
      let current = (contents.backEntries + contents.forwardEntries).first(where: { $0.index == entry.index })
    else { return }
    contents.go(to: current)
  }

  func goBack(_ tab: UUID) async {
    tabs[tab]?.goBack()
  }

  func goForward(_ tab: UUID) async {
    tabs[tab]?.goForward()
  }

  func reload(_ tab: UUID) async {
    tabs[tab]?.reload()
  }

  func stop(_ tab: UUID) async {
    tabs[tab]?.stop()
  }

  // The permissions the user allowed or blocked for the site of the tab's page.
  func sitePermissions(_ tab: UUID) -> [String: Bool] {
    tabs[tab]?.sitePermissions.mapValues(\.boolValue) ?? [:]
  }

  func setSitePermission(_ tab: UUID, _ key: String, allowed: Bool) {
    tabs[tab]?.setSitePermission(key, allowed: allowed)
  }

  func tab(of contents: ECWebContents) -> UUID? {
    tabs.first { $0.value === contents }?.key
  }
}

extension WebEngineClient: DependencyKey {
  static let liveValue = Self(
    create: { await Engine.shared.create($0, $1, $2) },
    load: { await Engine.shared.load($0, $1) },
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
    keepSessions: { Engine.sessions.keep($0) },
    copySession: { Engine.sessions.copy($0, to: $1) },
    events: { Engine.events }
  )
}
