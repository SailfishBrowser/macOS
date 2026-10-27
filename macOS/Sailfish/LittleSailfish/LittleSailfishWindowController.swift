import AppKit
import ComposableArchitecture
import SwiftUI

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // Keep Window on Top, which holds for every Little Sailfish.
  static var littleSailfishStaysOnTop: Self { Self[.appStorage("littleSailfishStaysOnTop"), default: false] }
}

// A Little Sailfish: just the command bar until a page is chosen, then a near screen-sized window with a 46 pt bar.
// It shows over other apps' full-screen windows. Esc closes its Open In panel or command bar; with a page it
// goes to the page.
final class LittleSailfishWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
  private let store: StoreOf<LittleSailfishFeature>
  private let app: StoreOf<AppFeature>
  private let openIn: (Space.ID) -> Void
  private let onClose: (CGRect) -> Void
  private var token: ObserveToken?
  private var levelToken: ObserveToken?
  private var escapeMonitor: Any?
  @Shared(.littleSailfishStaysOnTop) private var staysOnTop

  init(
    store: StoreOf<LittleSailfishFeature>, app: StoreOf<AppFeature>, openIn: @escaping (Space.ID) -> Void,
    onClose: @escaping (CGRect) -> Void
  ) {
    self.store = store
    self.app = app
    self.openIn = openIn
    self.onClose = onClose
    let window = NSWindow(
      contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.collectionBehavior = .moveToActiveSpace
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(button)?.isHidden = true
    }
    window.contentView = NSHostingView(rootView: LittleSailfishView(store: store, app: app, openIn: openIn))
    super.init(window: window)
    window.delegate = self
    token = observe { [weak self] in
      self?.layout(hasPage: store.tab != nil)
      self?.restoreFocus(isCovered: store.isOpenInMenuShown || store.commandBar != nil, tab: store.tab?.id)
    }
    levelToken = observe { [weak self, weak window] in
      window?.level = self?.staysOnTop == true ? .floating : .normal
    }
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
      guard event.window == window, event.keyCode == 53, store.isOpenInMenuShown else { return event }
      store.send(.setOpenInMenu(false))
      return nil
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // Tabs > Open in <space> ⌘O, shown while a Little Sailfish is key.
  @objc func openInSpace(_ sender: Any?) {
    guard let target = targetSpace else { return }
    openIn(target.id)
  }

  // The hidden Show Little Sailfish Open In Menu, ⇧⌘O.
  @objc func showOpenInMenu(_ sender: Any?) {
    store.send(.setOpenInMenu(!store.isOpenInMenuShown))
  }

  // Window > Stay On Top, which holds for every Little Sailfish.
  @objc func toggleStaysOnTop(_ sender: Any?) {
    $staysOnTop.withLock { $0.toggle() }
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(openInSpace(_:)):
      guard let target = targetSpace else { return false }
      item.title = "Open in \(target.name)"
      return store.tab != nil
    case #selector(showOpenInMenu(_:)):
      return store.tab != nil
    case #selector(toggleStaysOnTop(_:)):
      item.state = staysOnTop ? .on : .off
      return true
    default:
      return true
    }
  }

  private var targetSpace: Space? {
    AppFeature.State.littleSailfishSpaces(app.windows, for: store.profileID).first
  }

  private var hasPage: Bool?
  private var isCovered = false

  // The page takes the keys again once the Open In panel or the command bar over it goes.
  private func restoreFocus(isCovered: Bool, tab: Tab.ID?) {
    defer { self.isCovered = isCovered }
    guard self.isCovered, !isCovered, let tab, let view = Engine.shared.view(tab) else { return }
    window?.makeFirstResponder(view)
  }

  // The Little Sailfish frame: the screen's visible area inset 20 pt, no larger than the last window and
  // anchored at its top right; the command bar alone is a 490 pt wide clear window at that frame's top right
  // corner. Both appear in one frame, with no grow. A reopened Little Sailfish takes the frame it closed with.
  private func layout(hasPage: Bool) {
    guard hasPage != self.hasPage, let window, let screen = window.screen ?? NSScreen.main else { return }
    self.hasPage = hasPage
    window.isOpaque = hasPage
    window.backgroundColor = hasPage ? .windowBackgroundColor : .clear
    let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
    var size = visible.size
    if let last = app.windows.last(where: { !$0.isIncognito })?.frame {
      size.width = min(size.width, last.width)
      size.height = min(size.height, last.height)
    }
    if !hasPage {
      size = NSSize(width: 490, height: 360)
    }
    let frame = NSRect(x: visible.maxX - size.width, y: visible.maxY - size.height, width: size.width, height: size.height)
    window.setFrame(hasPage ? store.frame ?? frame : frame, display: true, animate: false)
  }

  func windowWillClose(_ notification: Notification) {
    escapeMonitor.map(NSEvent.removeMonitor)
    escapeMonitor = nil
    onClose(window?.frame ?? .zero)
  }
}
