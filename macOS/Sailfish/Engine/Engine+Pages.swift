import AppKit
@preconcurrency import EngineCore

// One of a tab's pages: its id, which names its saved history, and the engine that renders it.
struct PageRecord: Codable, Equatable, Sendable {
  let id: UUID
  let engine: PageEngineKind
}

// A tab's pages, oldest first, with one of them shown. Back at the start of the shown page's own history shows the
// page before it as it was left, and Forward at its end the page after it. Only the shown page is made when the tab
// is; a page behind it is made from its saved history once Back or Forward reaches it.
extension Engine {
  func create(_ tab: UUID, _ profile: UUID, _ incognito: Bool, pages: [PageRecord], shown: Int) async {
    _ = await context(profile)
    // Once quitting has closed every page, none is made.
    guard !isClosed else { return }
    register(tab, profile, incognito, pages: pages, shown: shown)
    makePage(pages[shown], of: tab)
  }

  // A tab of one Chromium page under the tab's id, as an extension opens one. Needs the profile's context loaded.
  @discardableResult
  func makeContents(_ tab: UUID, _ profile: UUID, _ incognito: Bool) -> ECWebContents {
    let context = register(tab, profile, incognito, pages: [PageRecord(id: tab, engine: .chromium)], shown: 0)
    return makeContents(tab, page: tab, context)
  }

  // A page the tab still has, such as a closing Peek that undo brings back, is saved and closed first, so the new
  // one starts from its history.
  @discardableResult
  func register(
    _ tab: UUID, _ profile: UUID, _ incognito: Bool, pages: [PageRecord], shown: Int
  ) -> ECBrowserContext {
    release(tab, keepingHistory: true).forEach { $0.close() }
    let context = loadedContext(profile, incognito)
    pageRecords[tab] = pages
    shownPages[tab] = shown
    tabContexts[tab] = context
    tabProfiles[tab] = profile
    if incognito {
      incognitoTabs.insert(tab)
    }
    return context
  }

  // Makes the tab's page, from its saved history if it has one. A restored WebKit page starts loading at once; a
  // restored Chromium page loads when the tab does, or when Back or Forward reaches it.
  @discardableResult
  private func makePage(_ record: PageRecord, of tab: UUID) -> (any TabPage)? {
    guard let context = tabContexts[tab], let profile = tabProfiles[tab] else { return nil }
    switch record.engine {
    case .chromium: return makeContents(tab, page: record.id, context)
    case .webkit: return makeWebKitPage(tab, page: record.id, profile: profile)
    }
  }

  // A Chromium page of the tab, given its saved history if it has one.
  @discardableResult
  func makeContents(_ tab: UUID, page id: UUID, _ context: ECBrowserContext) -> ECWebContents {
    let contents = ECWebContents(browserContext: context)
    contents.delegate = self
    livePages[id] = contents
    owners[ObjectIdentifier(contents)] = (tab, id)
    if let state = Self.sessions.load(id), contents.restoreSessionState(state) {
      restoredPages.insert(id)
      restoringPages.insert(id)
    }
    return contents
  }

  func shownRecord(_ tab: UUID) -> PageRecord? {
    guard let pages = pageRecords[tab], let shown = shownPages[tab] else { return nil }
    return pages[shown]
  }

  // The page the tab shows.
  func page(_ tab: UUID) -> (any TabPage)? {
    shownRecord(tab).flatMap { livePages[$0.id] }
  }

  func shownEngine(_ tab: UUID) -> PageEngineKind? {
    shownRecord(tab)?.engine
  }

  // The tab's shown page when Chromium renders it.
  func contents(_ tab: UUID) -> ECWebContents? {
    page(tab) as? ECWebContents
  }

  // The tab of a live page, shown or not.
  func tab(of page: AnyObject) -> UUID? {
    owners[ObjectIdentifier(page)]?.tab
  }

  // The tab of a page while the tab shows it: a hidden page's state reports are dropped.
  func shownTab(of page: AnyObject) -> UUID? {
    guard let owner = owners[ObjectIdentifier(page)], shownRecord(owner.tab)?.id == owner.page else { return nil }
    return owner.tab
  }

  // A request from a page behind the shown one waits until that page is shown, so nothing answers it on the page's
  // behalf; false for a shown page. A page closed first runs it then, and it finds no tab.
  func defers(_ page: AnyObject, _ request: @escaping @MainActor () -> Void) -> Bool {
    guard let owner = owners[ObjectIdentifier(page)], shownRecord(owner.tab)?.id != owner.page else { return false }
    pendingSheets[owner.page, default: []].append(request)
    return true
  }

  // A page behind the shown one closes alone; the shown one closes its tab.
  func closeRequested(by page: AnyObject) {
    guard let owner = owners[ObjectIdentifier(page)] else { return }
    if owner.page == shownRecord(owner.tab)?.id {
      Self.continuation.yield(.closeRequested(tab: owner.tab))
    } else {
      closePage(owner.page, of: owner.tab)
    }
  }

  // A navigation a page committed. In the shown page, one to another site clears the tab's engine choice, and a new
  // one (not a history step, nor the load of a restored history) closes the pages after it.
  func pageDidCommit(_ page: AnyObject, url: URL?, isNewNavigation: Bool) {
    guard let owner = owners[ObjectIdentifier(page)] else { return }
    let restoring = restoringPages.remove(owner.page) != nil
    guard owner.page == shownRecord(owner.tab)?.id else { return }
    if let choice = choices[owner.tab], let url, siteOf(url) != choice.site {
      choices[owner.tab] = nil
    }
    if isNewNavigation, !restoring {
      prune(owner.tab)
    }
  }

  // Back and Forward include the pages before and after the shown one; a page that is not alive lists nothing.
  func backEntries(_ tab: UUID) -> [HistoryEntry] {
    guard let pages = pageRecords[tab], let shown = shownPages[tab] else { return [] }
    return pages[...shown].reversed().enumerated().flatMap { offset, record -> [HistoryEntry] in
      guard let history = livePages[record.id]?.history(of: record.id) else { return [] }
      return offset == 0 ? history.back : (history.current.map { [$0] } ?? []) + history.back
    }
  }

  func forwardEntries(_ tab: UUID) -> [HistoryEntry] {
    guard let pages = pageRecords[tab], let shown = shownPages[tab] else { return [] }
    return pages[shown...].enumerated().flatMap { offset, record -> [HistoryEntry] in
      guard let history = livePages[record.id]?.history(of: record.id) else { return [] }
      return offset == 0 ? history.forward : (history.current.map { [$0] } ?? []) + history.forward
    }
  }

  func goToEntry(_ tab: UUID, _ entry: HistoryEntry) async {
    guard let index = pageRecords[tab]?.firstIndex(where: { $0.id == entry.page }), let page = livePages[entry.page]
    else { return }
    if index != shownPages[tab] {
      show(tab, index)
    }
    if page.history(of: entry.page).current?.index != entry.index {
      page.go(to: entry.index)
    }
  }

  func goBack(_ tab: UUID) async {
    guard let page = page(tab), let shown = shownPages[tab] else { return }
    if page.canGoBack {
      page.goBack()
    } else if shown > 0 {
      show(tab, shown - 1)
    }
  }

  func goForward(_ tab: UUID) async {
    guard let page = page(tab), let shown = shownPages[tab], let count = pageRecords[tab]?.count else { return }
    if page.canGoForward {
      page.goForward()
    } else if shown < count - 1 {
      show(tab, shown + 1)
    }
  }

  func reload(_ tab: UUID) async {
    page(tab)?.reload()
  }

  func stop(_ tab: UUID) async {
    page(tab)?.stop()
  }

  // Shows the tab's page at `index`, muted as the tab is, and reports it at once. A page that is not alive is made
  // from its saved history and loads it; one without saved history is dropped instead.
  private func show(_ tab: UUID, _ index: Int) {
    guard let pages = pageRecords[tab], let hidden = shownRecord(tab) else { return }
    let record = pages[index]
    if livePages[record.id] == nil {
      let page = makePage(record, of: tab)
      guard restoredPages.remove(record.id) != nil else { return closePage(record.id, of: tab) }
      (page as? ECWebContents)?.loadIfNeeded()
    }
    hold(tab, hidden.id)
    livePages[hidden.id]?.pauseMedia()
    if let page = livePages[record.id], let muted = livePages[hidden.id]?.isMuted, page.isMuted != muted {
      page.isMuted = muted
    }
    shownPages[tab] = index
    hoveredLinks[tab] = nil
    selections[tab] = nil
    reportShown(tab)
  }

  // The open permission request and dialog of a page being hidden wait until it is shown again.
  func hold(_ tab: UUID, _ page: UUID) {
    if let request = permissionRequests.removeValue(forKey: tab) {
      pendingSheets[page, default: []].append { [weak self] in
        guard let self, self.shownRecord(tab)?.id == page else { return request.answer(false) }
        self.permissionRequests[tab] = request
      }
    }
    if let dialog = dialogs.removeValue(forKey: tab) {
      pendingSheets[page, default: []].append { [weak self] in
        guard let self, self.shownRecord(tab)?.id == page else { return dialog.answer(false, "") }
        self.dialogs[tab] = dialog
      }
    }
  }

  // Closes one page behind the shown one and drops it from the tab's list.
  func closePage(_ id: UUID, of tab: UUID) {
    guard var pages = pageRecords[tab], let shown = shownPages[tab],
      let index = pages.firstIndex(where: { $0.id == id }), index != shown
    else { return }
    dropPage(pages.remove(at: index))
    pageRecords[tab] = pages
    shownPages[tab] = index < shown ? shown - 1 : shown
    reportShown(tab)
  }

  // Closes the pages after the shown one, as a new navigation in it ends its forward history.
  func prune(_ tab: UUID) {
    guard var pages = pageRecords[tab], let shown = shownPages[tab], shown < pages.count - 1 else { return }
    pages[(shown + 1)...].forEach { dropPage($0) }
    pages.removeSubrange((shown + 1)...)
    pageRecords[tab] = pages
    reportShown(tab)
  }

  // Closes a page that leaves its tab's list, and forgets its saved history.
  func dropPage(_ record: PageRecord) {
    releasePage(record.id)?.close()
    Self.store(record.engine).forget(record.id)
  }

  func reportShown(_ tab: UUID) {
    guard let page = page(tab) else { return }
    loadProgress[tab] = page.loadProgress
    report(tab, page)
  }

  // Reports the tab's shown page with its list; Back and Forward also reach the pages beside it.
  func report(_ tab: UUID, _ page: any TabPage) {
    guard let pages = pageRecords[tab], let shown = shownPages[tab] else { return }
    var state = page.webPage(pages: pages, shown: shown)
    state.canGoBack = state.canGoBack || shown > 0
    state.canGoForward = state.canGoForward || shown < pages.count - 1
    let previous = lastPages[tab]
    guard previous != state else { return }
    lastPages[tab] = state
    updateReader(tab, page, from: previous, to: state)
    Self.continuation.yield(.updated(tab: tab, page: state))
  }

  nonisolated static func store(_ engine: PageEngineKind) -> SessionStore {
    switch engine {
    case .chromium: sessions
    case .webkit: webKitSessions
    }
  }

  func saveSessions() {
    for tab in pageRecords.keys {
      saveSessions(of: tab)
    }
  }

  private func saveSessions(of tab: UUID) {
    for record in pageRecords[tab] ?? [] {
      guard let state = livePages[record.id]?.sessionState else { continue }
      Self.store(record.engine).save(record.id, state, inMemory: incognitoTabs.contains(tab))
    }
  }

  // Forgets the tab and detaches from its pages, which the caller closes: a web contents being destroyed reports
  // navigation state changes, which must not reach the shell once it has let the tab go.
  func release(_ tab: UUID, keepingHistory: Bool) -> [any TabPage] {
    if keepingHistory {
      saveSessions(of: tab)
    }
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
    fullScreenPages[tab] = nil
    incognitoTabs.remove(tab)
    lastPages[tab] = nil
    tabContexts[tab] = nil
    tabProfiles[tab] = nil
    choices[tab] = nil
    findRequests[tab] = nil
    shownPages[tab] = nil
    return (pageRecords.removeValue(forKey: tab) ?? []).compactMap { releasePage($0.id) }
  }

  // Waiting sheets run once the page is gone, and find no tab.
  private func releasePage(_ id: UUID) -> (any TabPage)? {
    restoredPages.remove(id)
    restoringPages.remove(id)
    let page = livePages.removeValue(forKey: id)
    if let page {
      owners[ObjectIdentifier(page)] = nil
    }
    (page as? ECWebContents)?.delegate = nil
    pendingSheets.removeValue(forKey: id)?.forEach { $0() }
    return page
  }
}
