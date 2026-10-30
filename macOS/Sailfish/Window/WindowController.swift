import AppKit
import ComposableArchitecture
@preconcurrency import EngineCore
import SwiftUI

// AppKit leaves full screen on one Esc that nothing handled; the controller's monitor does a two-step instead.
private final class BrowserWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) {}
}

final class WindowController: NSWindowController, NSWindowDelegate {
  let store: StoreOf<WindowFeature>
  private let onClose: () -> Void
  private var token: ObserveToken?
  private var undoToken: ObserveToken?
  private var titleToken: ObserveToken?
  private var fullScreenToken: ObserveToken?
  // The page filling the window in element full screen, and whether the window went full screen for it.
  private weak var fullScreenPage: ECWebContents?
  private var isFullScreenForPage = false
  private var swipeMonitor: Any?
  private var escapeMonitor: Any?
  private var controlMonitor: Any?
  private var mouseButtonMonitor: Any?
  // Whether the current scroll gesture swipes between spaces; nil until its first few points of travel decide.
  private var isSwiping: Bool? = false
  // What the current gesture moves, fixed as it begins: a swipe that starts on the Library or the floating card
  // closes it and never reaches the strip, through its momentum too.
  private var surface: WindowFeature.SwipeSurface?
  // The floating card goes once per gesture.
  private var isCardDismissed = false
  // The gesture's events while its direction is undecided, replayed to the sidebar if it turns out to scroll.
  private var held: [NSEvent] = []
  private static let lockTravel: CGFloat = 6
  // The fingers' movements over the last tenth of a second, for their speed when they lift.
  private var swipeSamples: [(time: TimeInterval, delta: CGFloat)] = []
  // The strip's settle, pending: a slow lift waits a moment for momentum events, which tell which way the
  // fingers were going.
  private var swipeSettle: Task<Void, Never>?
  private static let swipeWindow: TimeInterval = 0.1
  private static let momentumWait: TimeInterval = 0.06
  @Shared(.swipeCommitSpeed) private var commitSpeed
  // The window's undo manager, holding one entry for each of the store's undo stack.
  private let undos = UndoManager()
  private var undoCount = 0

  init(store: StoreOf<WindowFeature>, downloads: StoreOf<DownloadsFeature>, onClose: @escaping () -> Void) {
    self.store = store
    self.onClose = onClose
    let window = BrowserWindow(
      contentRect: store.frame ?? NSRect(x: 0, y: 0, width: 1470, height: 804),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false
    )
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 640, height: 400)
    let hostingView = NSHostingView(rootView: WindowView(store: store).environment(downloads))
    hostingView.sizingOptions = []
    window.contentView = hostingView
    if let frame = store.frame {
      window.setFrame(frame, display: false)
    } else {
      window.center()
    }
    super.init(window: window)
    window.delegate = self
    token = observe { [weak window] in
      let isLight = !store.isIncognito && Theme.isLight(store.themePreview ?? store.spaces.selected.theme)
      let name: NSAppearance.Name = isLight ? .aqua : .darkAqua
      if window?.appearance?.name != name {
        window?.appearance = NSAppearance(named: name)
      }
    }
    undoToken = observe { [weak self] in self?.registerUndos() }
    // The window is titled after the selected tab, which Mission Control and the Window menu show.
    titleToken = observe { [weak window] in
      let title = store.spaces.selected.selectedTab?.displayTitle ?? ""
      if window?.title != title { window?.title = title }
    }
    fullScreenToken = observe { [weak self] in self?.syncPageFullScreen() }
    // The sidebar draws the traffic lights.
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(button)?.isHidden = true
    }
    swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self else { return event }
      return swipe(event)
    }
    // Mouse buttons 3 and 4 over the sidebar switch to the previous and next space.
    mouseButtonMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
      guard let self, event.window == window, [3, 4].contains(event.buttonNumber), store.sidebar.isVisible,
        event.locationInWindow.x < store.sidebar.visibleWidth
      else { return event }
      store.send(.spaces(.cycle(event.buttonNumber == 3 ? -1 : 1)))
      return nil
    }
    // Esc closes Peek even while its page has focus, which a menu key equivalent would not reach.
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.window == window else { return event }
      // One Esc leaves a page's element full screen.
      if event.keyCode == 53, let page = shownFullScreenPage?.page {
        page.exitFullscreen(resizingView: true)
        return nil
      }
      // Esc leaves the command bar wherever focus is: the bar's own Esc needs its field to have the keys. Text being
      // composed keeps its Esc, which cancels the composition.
      if event.keyCode == 53, let bar = store.commandBar, (window.firstResponder as? NSTextView)?.hasMarkedText() != true {
        store.send(bar.keyword != nil || bar.isActions ? .commandBar(.presented(.leaveKeyword)) : .commandBar(.dismiss))
        return nil
      }
      if event.keyCode == 53, store.peek != nil {
        // Sent after the key event, whose handling would skip Peek's closing animation.
        DispatchQueue.main.async { self.store.send(.closePeek) }
        return nil
      }
      // Esc leaves Reader View wherever focus is, its own page included.
      if event.keyCode == 53, let tab = store.spaces.selected.selectedTabID, Engine.shared.readers[tab] != nil {
        Engine.shared.toggleReader(tab)
        return nil
      }
      // ⌃W in the open tab switcher closes the tab it is on.
      if event.charactersIgnoringModifiers?.lowercased() == "w", event.modifierFlags.contains(.control), store.recentCycle != nil {
        store.send(.closeInRecentCycle, animation: Motion.row)
        return nil
      }
      // Full screen: Esc shows how to leave, and a second Esc while that shows leaves.
      if event.keyCode == 53, window.styleMask.contains(.fullScreen) {
        if let toast = store.toast, toast.action == .editShortcut {
          store.send(.dismissToast(toast.id))
          window.toggleFullScreen(nil)
          return nil
        }
        store.send(.showToast("⎋ again to exit fullscreen", .editShortcut))
      }
      return paneShortcut(event) ? nil : event
    }
    // Releasing ⌃ ends a ⌃Tab cycle on the tab it reached.
    controlMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      if let self, store.recentCycle != nil, !event.modifierFlags.contains(.control) {
        store.send(.endRecentCycle)
      }
      return event
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // The sidebar swipe: a horizontal two-finger scroll drags the spaces' strip, and its momentum is spent.
  private func swipe(_ event: NSEvent) -> NSEvent? {
    guard event.window == window else { return event }
    // Spaces also switch on a mouse wheel turned with ⇧ over the sidebar, one space a notch.
    if event.phase.isEmpty, event.momentumPhase.isEmpty, !event.hasPreciseScrollingDeltas,
      event.modifierFlags.contains(.shift), store.sidebar.isVisible, event.locationInWindow.x < store.sidebar.width + 3
    {
      let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
      let spaces = store.spaces.spaces
      // It stops at the first and last space rather than wrapping round on a fast spin.
      guard delta != 0, let index = spaces.index(id: store.spaces.selectedID),
        spaces.indices.contains(index + (delta < 0 ? 1 : -1))
      else { return nil }
      store.send(.spaces(.select(spaces[index + (delta < 0 ? 1 : -1)].id)))
      return nil
    }
    if event.phase == .began {
      // A lift that never arrived still ends the strip's drag, so a new gesture always starts from a settled
      // space; fingers resting mid-gesture send no events and keep the strip where it is.
      if store.sidebar.swipe != nil { endSwipe(velocity: velocity(at: event.timestamp)) }
      let x = event.locationInWindow.x
      surface =
        if store.isLibraryOpen { x < WindowFeature.libraryWidth ? .library : nil }
        else if store.sidebar.isFloating { store.sidebar.isPeeking && x < store.sidebar.width + 3 ? .card : nil }
        else { x < store.sidebar.width + 3 ? .strip : nil }
      isSwiping = surface == nil ? false : nil
      isCardDismissed = false
      swipeSamples = []
      held = []
    }
    if isSwiping == nil, !event.phase.isEmpty {
      // The direction locks once the fingers have travelled a few points, not on their first wobble: a
      // swipe that starts a little crooked still moves the strip, and a scroll still scrolls.
      held.append(event)
      let dx = held.reduce(0) { $0 + $1.scrollingDeltaX }
      let dy = held.reduce(0) { $0 + $1.scrollingDeltaY }
      let lifted = event.phase.contains(.ended) || event.phase.contains(.cancelled)
      guard abs(dx) + abs(dy) >= Self.lockTravel || lifted else { return nil }
      isSwiping = abs(dx) > abs(dy)
      let events = held
      held = []
      if isSwiping == true { events.forEach(track) } else { events.forEach { window?.sendEvent($0) } }
      return nil
    }
    guard isSwiping == true, !event.phase.isEmpty || !event.momentumPhase.isEmpty else { return event }
    track(event)
    return nil
  }

  // One event of a swipe: the strip, or the Library over it, follows the fingers, and their lift settles it. On the
  // floating card a swipe to the left puts the card away; nothing else of it moves anything.
  private func track(_ event: NSEvent) {
    if surface == .card {
      if !isCardDismissed, event.momentumPhase.isEmpty, event.scrollingDeltaX < 0 {
        isCardDismissed = true
        store.send(.sidebar(.peek(false)))
      }
      return
    }
    if !event.momentumPhase.isEmpty {
      // Momentum after a slow lift says which way the fingers were still going; the strip follows it.
      if store.sidebar.swipe != nil, event.scrollingDeltaX != 0 {
        let speed = max(abs(event.scrollingDeltaX) * 60, commitSpeed)
        endSwipe(velocity: event.scrollingDeltaX < 0 ? -speed : speed)
      }
    } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      let velocity = velocity(at: event.timestamp)
      if abs(velocity) >= commitSpeed {
        endSwipe(velocity: velocity)
      } else {
        settle(after: Self.momentumWait) { $0.endSwipe(velocity: velocity) }
      }
    } else if event.phase != .began, event.phase != .mayBegin {
      swipeSamples.append((event.timestamp, event.scrollingDeltaX))
      swipeSamples.removeAll { event.timestamp - $0.time > Self.swipeWindow }
      store.send(.swipe(event.scrollingDeltaX))
    }
  }

  // The fingers' speed in scroll points per second over the last tenth of a second before this moment; fingers
  // that rested before lifting carry none.
  private func velocity(at time: TimeInterval) -> CGFloat {
    let recent = swipeSamples.filter { time - $0.time <= Self.swipeWindow }
    guard let first = recent.first else { return 0 }
    return recent.reduce(0) { $0 + $1.delta } / max(time - first.time, 1.0 / 120)
  }

  private func settle(after delay: TimeInterval, _ action: @escaping (WindowController) -> Void) {
    swipeSettle?.cancel()
    swipeSettle = Task { [weak self] in
      guard (try? await Task.sleep(for: .seconds(delay))) != nil, let self else { return }
      action(self)
    }
  }

  private func endSwipe(velocity: CGFloat) {
    swipeSettle?.cancel()
    swipeSettle = nil
    swipeSamples = []
    guard store.sidebar.swipe != nil else { return }
    store.send(.endSwipe(surface ?? .strip, width: store.sidebar.visibleWidth, velocity: velocity))
  }

  private var shownFullScreenPage: (page: ECWebContents, origin: URL?)? {
    store.spaces.selected.selectedTabID.flatMap { Engine.shared.fullScreenPages[$0] }
  }

  // A page in element full screen fills the screen while its tab is the one shown: the window goes full screen for
  // it unless it already is, and leaves with it. This window's other pages leave element full screen.
  private func syncPageFullScreen() {
    guard let window else { return }
    let engine = Engine.shared
    let shown = store.spaces.selected.selectedTabID
    for (tab, entry) in engine.fullScreenPages
    where (tab != shown || engine.contents(tab) !== entry.page)
      && (store.spaces.spaces.contains(where: { $0.tabs[id: tab] != nil }) || store.peek?.tab.id == tab)
    {
      entry.page.exitFullscreen(resizingView: false)
    }
    // A WebKit page's element full screen is WebKit's own window, which a page no longer shown leaves the same way.
    for case let page as WebKitPage in engine.livePages.values {
      guard let tab = engine.tab(of: page), tab != shown || engine.page(tab) !== page,
        store.spaces.spaces.contains(where: { $0.tabs[id: tab] != nil })
      else { continue }
      page.exitFullScreen()
    }
    let page = shownFullScreenPage?.page
    guard page !== fullScreenPage else { return }
    fullScreenPage = page
    if page == nil {
      if isFullScreenForPage, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    } else if window.styleMask.contains(.fullScreen) {
      showFullScreenToast()
    } else {
      isFullScreenForPage = true
      // A turn later, so the window's transition starts from the page alone.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if fullScreenPage == nil { isFullScreenForPage = false } else { window.toggleFullScreen(nil) }
      }
    }
  }

  // Names the site filling the screen, as Chrome's full screen bubble does.
  private func showFullScreenToast() {
    let host = shownFullScreenPage?.origin?.host()
    store.send(.showToast(host.map { "\($0) is full screen. To exit, press ⎋" } ?? "To exit full screen, press ⎋"))
  }

  // ⌃⇧1–4 focus a split's pane and ⌃⇧] / ⌃⇧[ step through its panes. Read by key code, as Shift turns
  // the characters a menu key equivalent would match into "!" and "}".
  private func paneShortcut(_ event: NSEvent) -> Bool {
    let space = store.spaces.selected
    guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.control, .shift],
      space.split(of: space.selectedTabID) != nil
    else { return false }
    let action: TabsFeature.Action
    switch event.keyCode {
    case 18, 19, 20, 21: action = .selectPane([18: 0, 19: 1, 20: 2, 21: 3][event.keyCode]!)
    case 30: action = .cyclePane(1)
    case 33: action = .cyclePane(-1)
    default: return false
    }
    store.send(.tab(action, in: space.id))
    return true
  }

  private func registerUndos() {
    let count = store.undoStack.count
    var from = undoCount
    // Entries a toast's Undo popped leave the manager too, so Edit > Undo stays in step; during the manager's
    // own undo it already dropped the entry.
    if count < undoCount, !undos.isUndoing {
      undos.removeAllActions(withTarget: self)
      from = 0
    }
    for index in min(from, count)..<count {
      undos.registerUndo(withTarget: self) { $0.store.send(.undo) }
      undos.setActionName(store.undoStack[index].name)
    }
    undoCount = count
  }

  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
    undos
  }

  @objc func reopenClosedTab(_ sender: Any?) {
    store.send(.reopenClosedTab)
  }

  private var selectedSpace: Space.ID { store.spaces.selectedID }

  @objc func newTab(_ sender: Any?) {
    store.send(.showCommandBar)
  }

  @objc func openLocation(_ sender: Any?) {
    store.send(.editSelectedTab)
  }

  @objc func copyURL(_ sender: Any?) {
    guard let url = store.spaces.selected.selectedTab?.url else { return }
    copyLink(url)
    store.send(.showToast("Copied Current URL"))
  }

  @objc func find(_ sender: Any?) {
    store.send(.showFind)
  }

  @objc func findNext(_ sender: Any?) {
    store.send(store.find == nil ? .showFind : .find(.presented(.next)))
  }

  @objc func findPrevious(_ sender: Any?) {
    store.send(store.find == nil ? .showFind : .find(.presented(.previous)))
  }

  @objc func useSelectionForFind(_ sender: Any?) {
    guard let tab = store.spaces.selected.selectedTabID, let text = Engine.shared.selections[tab] else { return }
    store.send(.useSelectionForFind(text))
  }

  @objc func nextTab(_ sender: Any?) {
    store.send(.tab(.cycle(1), in: selectedSpace))
  }

  @objc func previousTab(_ sender: Any?) {
    store.send(.tab(.cycle(-1), in: selectedSpace))
  }

  @objc func nextSpace(_ sender: Any?) {
    store.send(.spaces(.cycle(1)))
  }

  @objc func previousSpace(_ sender: Any?) {
    store.send(.spaces(.cycle(-1)))
  }

  @objc func closeTab(_ sender: Any?) {
    // ⌘W closes an open Peek, not the tab under it.
    if store.peek != nil {
      store.send(.closePeek)
    } else if let tab = store.spaces.selected.selectedTabID {
      store.send(.tab(.close(tab), in: selectedSpace))
    } else {
      window?.performClose(sender)
    }
  }

  @objc func showExtensions(_ sender: Any?) {
    let space = store.spaces.selected
    Task {
      let context = await Engine.shared.context(for: space)
      var sheet: NSWindow?
      let close = { [weak self] in
        if let sheet { self?.window?.endSheet(sheet) }
      }
      let view = ExtensionsView(context: context) { [weak self] id in
        close()
        self?.store.send(.tab(.open(URL(string: "chrome://extensions/?id=\(id)")!), in: space.id))
      } done: {
        close()
      }
      sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
      window?.beginSheet(sheet!, completionHandler: nil)
    }
  }

  // The command bar picks the pane by the sender's tag. The item of the pane the Library is open on
  // closes it.
  @objc func openLibrary(_ sender: Any?) {
    let pane = LibraryFeature.Pane(rawValue: (sender as? NSMenuItem)?.tag ?? 0)!
    store.send(store.isLibraryOpen && store.library?.pane == pane ? .toggleLibrary : .showLibrary(pane))
  }

  @objc func toggleLibrary(_ sender: Any?) {
    store.send(.toggleLibrary)
  }

  @objc func importBrowserData(_ sender: Any?) {
    store.send(.showImport)
  }

  @objc func importFromArc(_ sender: Any?) {
    store.send(.showArcImport)
  }

  @objc func toggleSidebarDocking(_ sender: Any?) {
    store.send(.sidebar(.toggle))
  }

  @objc func goBack(_ sender: Any?) {
    store.send(.tab(.goBack, in: selectedSpace))
  }

  @objc func goForward(_ sender: Any?) {
    store.send(.tab(.goForward, in: selectedSpace))
  }

  // ⌘← and ⌘→, which WindowMenuActions leaves to a focused text field.
  @objc func goBackWithArrow(_ sender: Any?) {
    goBack(sender)
  }

  @objc func goForwardWithArrow(_ sender: Any?) {
    goForward(sender)
  }

  @objc func reload(_ sender: Any?) {
    store.send(.tab(.reload, in: selectedSpace))
  }

  // A ⌃ released in another window or app never reaches this one, so leaving the window ends a ⌃Tab cycle.
  func windowDidResignKey(_ notification: Notification) {
    if store.recentCycle != nil {
      store.send(.endRecentCycle)
    }
  }

  // A page that left while the window was going full screen for it takes the window back out.
  func windowDidEnterFullScreen(_ notification: Notification) {
    guard !isFullScreenForPage || fullScreenPage != nil else { return window!.toggleFullScreen(nil) }
    showFullScreenToast()
  }

  // Leaving full screen any other way than Esc takes the page out of element full screen too.
  func windowWillExitFullScreen(_ notification: Notification) {
    isFullScreenForPage = false
    shownFullScreenPage?.page.exitFullscreen(resizingView: true)
  }

  func windowDidResize(_ notification: Notification) {
    store.send(.frameChanged(window!.frame))
  }

  func windowDidMove(_ notification: Notification) {
    store.send(.frameChanged(window!.frame))
  }

  func windowWillClose(_ notification: Notification) {
    swipeMonitor.map(NSEvent.removeMonitor)
    escapeMonitor.map(NSEvent.removeMonitor)
    controlMonitor.map(NSEvent.removeMonitor)
    mouseButtonMonitor.map(NSEvent.removeMonitor)
    onClose()
  }
}
