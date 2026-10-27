import AppKit
import EngineCore
import SwiftUI

// A back or forward button: a click goes one step, ⌘-click or a middle click opens the nearest entry in
// a new tab, and press-and-hold lists the entries, nearest first, with their favicons.
struct HistoryButton: View {
  enum Direction {
    case back, forward
  }

  let direction: Direction
  let tab: Tab?
  let space: Space
  let send: (TabsFeature.Action) -> Void
  @State private var isHovering = false
  @State private var isPressed = false
  // The catcher's view, which the accessibility action anchors the menu to.
  @State private var anchor = ViewAnchor()

  private var isEnabled: Bool {
    direction == .back ? tab?.canGoBack == true : tab?.canGoForward == true
  }

  var body: some View {
    Image(systemName: direction == .back ? "arrow.left" : "arrow.right")
      // The arrows are 15x12 pt on a 34 pt pitch: SF Symbols at 16 pt.
      .font(.system(size: 16, weight: .medium))
      .foregroundStyle(Theme.icon)
      .frame(width: 34, height: 34)
      .background(isHovering && isEnabled ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
      .scaleEffect(isPressed ? 0.88 : 1)
      .animation(Motion.row, value: isPressed)
      // Disabled arrows are white at 25%: the icon's 60% at 0.42.
      .opacity(isEnabled ? 1 : 0.42)
      .overlay {
        if isEnabled {
          HoldCatcher(
            isPressed: $isPressed, isHovering: $isHovering, anchor: anchor, clicked: go, openNearest: openNearest,
            held: showMenu)
        }
      }
      .accessibilityElement()
      .accessibilityLabel(direction == .back ? "Back" : "Forward")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { go() }
      .accessibilityAction(named: "Show History") { anchor.view.map(showMenu) }
  }

  // The entries behind or ahead of the shown page, nearest first, read when a menu or a ⌘-click needs them.
  private func entries() -> [ECNavigationEntry] {
    guard let contents = tab.flatMap({ Engine.shared.tabs[$0.id] }) else { return [] }
    return direction == .back ? contents.backEntries : contents.forwardEntries
  }

  private func go() {
    send(direction == .back ? .goBack : .goForward)
  }

  private func goToEntry(_ index: Int) {
    send(.goToEntry(index: index))
  }

  private func openInNewTab(_ url: URL) {
    send(.open(url))
  }

  private func favicon(_ url: URL) async -> NSImage? {
    await Autocomplete.favicon(space.profileID, space.isIncognito, url)
  }

  private func openNearest() {
    entries().first.map { openInNewTab($0.url) }
  }

  // Chrome's back and forward menus list up to 15 entries, and so do these.
  private func showMenu(from view: NSView) {
    let listed = entries().prefix(15)
    guard !listed.isEmpty else { return }
    let menu = NSMenu()
    let items = listed.map { entry in
      let item = HistoryMenuItem(entry: entry, goToEntry: goToEntry, openInNewTab: openInNewTab)
      menu.addItem(item)
      return item
    }
    Task { @MainActor in
      for item in items {
        guard let image = await favicon(item.url) else { continue }
        image.size = NSSize(width: 16, height: 16)
        item.image = image
      }
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
  }
}

// An entry in a history menu, with its favicon; ⌘ held while choosing it opens it in a new tab, as in Chrome.
private final class HistoryMenuItem: NSMenuItem {
  let url: URL
  private let index: Int
  private let goToEntry: (Int) -> Void
  private let openInNewTab: (URL) -> Void

  init(entry: ECNavigationEntry, goToEntry: @escaping (Int) -> Void, openInNewTab: @escaping (URL) -> Void) {
    url = entry.url
    index = entry.index
    self.goToEntry = goToEntry
    self.openInNewTab = openInNewTab
    super.init(title: Self.label(entry.url), action: #selector(choose), keyEquivalent: "")
    target = self
    let placeholder = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!
    placeholder.size = NSSize(width: 16, height: 16)
    image = placeholder
  }

  // Each page is listed by its address without the scheme: "example.com", "httpbin.org/delay/4".
  private static func label(_ url: URL) -> String {
    guard let host = url.host() else { return url.absoluteString }
    let path = url.path() == "/" ? "" : url.path()
    return host + path + (url.query().map { "?" + $0 } ?? "")
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  @objc private func choose() {
    if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
      openInNewTab(url)
    } else {
      goToEntry(index)
    }
  }
}

// Takes the button's clicks: a press held for 0.4 s shows the menu, a shorter one is a click (⌘-click and a middle
// click open the nearest entry), and hovering and pressing are reported for the button's look.
@MainActor
final class ViewAnchor {
  weak var view: NSView?
}

private struct HoldCatcher: NSViewRepresentable {
  @Binding var isPressed: Bool
  @Binding var isHovering: Bool
  let anchor: ViewAnchor
  let clicked: () -> Void
  let openNearest: () -> Void
  let held: (NSView) -> Void

  func makeNSView(context: Context) -> Catcher {
    let view = Catcher()
    anchor.view = view
    return view
  }

  func updateNSView(_ view: Catcher, context: Context) {
    view.setPressed = { isPressed = $0 }
    view.setHovering = { isHovering = $0 }
    view.clicked = clicked
    view.openNearest = openNearest
    view.held = held
  }

  static func dismantleNSView(_ view: Catcher, coordinator: ()) {
    view.setPressed?(false)
    view.setHovering?(false)
  }

  final class Catcher: NSView {
    var setPressed: ((Bool) -> Void)?
    var setHovering: ((Bool) -> Void)?
    var clicked: (() -> Void)?
    var openNearest: (() -> Void)?
    var held: ((NSView) -> Void)?
    private var hold: Task<Void, Never>?
    private var menuShown = false

    // The header's background drags the window; a press on the button must reach it instead.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(
        NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovering?(true) }

    override func mouseExited(with event: NSEvent) { setHovering?(false) }

    override func mouseDown(with event: NSEvent) {
      menuShown = false
      setPressed?(true)
      hold = Task { [weak self] in
        try? await Task.sleep(for: .seconds(0.4))
        guard !Task.isCancelled, let self else { return }
        menuShown = true
        setPressed?(false)
        held?(self)
      }
    }

    override func mouseUp(with event: NSEvent) {
      hold?.cancel()
      hold = nil
      setPressed?(false)
      guard !menuShown, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
      if event.modifierFlags.contains(.command) {
        openNearest?()
      } else {
        clicked?()
      }
    }

    override func otherMouseDown(with event: NSEvent) {}

    override func otherMouseUp(with event: NSEvent) {
      if event.buttonNumber == 2 { openNearest?() }
    }
  }
}
