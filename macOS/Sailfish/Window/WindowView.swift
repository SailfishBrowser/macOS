import ComposableArchitecture
import SwiftUI

struct WindowView: View {
  @Bindable var store: StoreOf<WindowFeature>
  @State private var themePreview: SpaceTheme?
  // The sidebar's width when a drag on its edge began.
  @State private var resizeStart: Double?
  @State private var downloadThrows = DownloadThrows()

  var body: some View {
    let isFloating = store.sidebar.isFloating
    let theme = themePreview ?? store.spaces.selected.theme
    let background = store.isIncognito ? Theme.incognitoWindow : LinearGradient(theme: theme)
    ZStack(alignment: .topLeading) {
      // The Library slides in from the left over the sidebar, which stays put, and pushes the page right; a swipe
      // past the first space drags it with the fingers.
      GeometryReader { proxy in layered(proxy.size, isFloating: isFloating, background: background) }
      // The Library opens and closes on the space switch's curve, as does a swipe that settles.
      .animation(store.sidebar.swipe == nil ? Motion.layout : nil, value: store.isLibraryOpen)
      .animation(store.sidebar.swipe == nil ? Motion.layout : nil, value: store.sidebar.swipe)
      .animation(Motion.layout, value: store.library?.pane)

      if let commandBar = store.scope(state: \.commandBar, action: \.commandBar.presented) {
        GeometryReader { proxy in
          ZStack(alignment: .top) {
            // The page stays live under the bar: it scrolls and hovers, and a click on it closes the bar (the
            // bar's own mouse monitor) and reaches the page.
            Color.clear.allowsHitTesting(false)
            // The bar follows the window's appearance, light on light themes.
            CommandBarView(
              store: commandBar,
              accent: store.isIncognito ? Theme.accent : Theme.CommandBar.accent(store.spaces.selected.theme)
            ) { store.send(.commandBar(.dismiss)) }
              // The five-row panel centers in the window, 7 pt above the middle: within 2 pt of two
              // measurements, 176 pt from the top of a 696 pt window and 233 of 804.
              .padding(.top, max((proxy.size.height - Theme.CommandBar.fiveRowHeight) / 2 - 7, 0))
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // Only the window's own background moves it, so dragging a sidebar row never does.
    .background {
      backdrop(background)
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
    }
    .overlay { switcher }
    .animation(Motion.row, value: store.recentCycle != nil)
    .overlay(alignment: store.toast?.placement.isTop == true ? .topTrailing : .bottom) {
      if let toast = store.toast {
        ToastView(
          toast: toast,
          perform: { action in
            if action == .editShortcut {
              AppCommands.perform(Command(title: "Edit Keyboard Shortcuts", symbol: "", action: "showSettings:", tag: SettingsPane.shortcuts.rawValue))
            }
            store.send(.toastAction(action))
          },
          close: { store.send(.dismissToast(toast.id)) }
        )
        // The top-right pill sits over the page's corner, clear of the window's controls.
        .padding(.bottom, toast.placement == .bottom ? 18 : 0)
        // The corner toast sits 4 pt from the window's top and right edges.
        .padding(.top, toast.placement == .corner ? 4 : toast.placement.isTop ? 20 : 0)
        .padding(.trailing, toast.placement == .corner ? 4 : toast.placement.isTop ? 28 : 0)
        .transition(toast.placement.isTop ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .id(toast.id)
      }
    }
    .animation(Motion.layout, value: store.toast?.id)
    .onPreferenceChange(ThemePreview.self) { themePreview = $0 }
    .environment(
      \.colorScheme,
      !store.isIncognito && Theme.isLight(theme) ? .light : .dark)
    // Above the page and the sidebar both, as a thrown download crosses from one to the other.
    .overlay {
      DownloadThrowLayer(canThrow: (!isFloating || store.sidebar.isPeeking) && !store.isLibraryOpen)
    }
    .coordinateSpace(.named(DownloadThrows.space))
    .environment(downloadThrows)
    .ignoresSafeArea()
    .animation(store.sidebar.isPeeking ? Motion.peek : Motion.peekOut, value: store.sidebar.isPeeking)
    .animation(store.sidebar.isFloating ? Motion.sidebarHide : Motion.sidebarShow, value: store.sidebar.isFloating)
    .sheet(item: $store.scope(state: \.importer, action: \.importer)) { ImportView(store: $0) }
    // Loads the profile, which reports its downloads, before any of its pages open.
    .task(id: store.spaces.selected.profileID) { _ = await Engine.shared.context(for: store.spaces.selected) }
  }

  @ViewBuilder private var switcher: some View {
    if let cycle = store.recentCycle {
      TabSwitcher(cycle: cycle, spaces: store.spaces.spaces).transition(.opacity)
    }
  }

  @ViewBuilder private func layered(_ size: CGSize, isFloating: Bool, background: LinearGradient) -> some View {
    // The Spaces pane covers all of the window but a sliver of the page.
    let open = store.library?.pane == .spaces ? size.width - 46 : WindowFeature.libraryWidth
    let side: CGFloat = isFloating ? 0 : store.sidebar.width
    let shown = libraryShown(span: isFloating ? WindowFeature.libraryWidth : side)
    let push = shown * max(open - side, 0)
    // The page narrows only as far as beside the Library's column; past that it slides off the window's edge.
    let narrow = min(push, max(WindowFeature.libraryWidth - side, 0))
    ZStack(alignment: .topLeading) {
      browser(isFloating: isFloating, background: background, library: (shown: shown, push: push))
    }
    // The page's frame changes at once, never with an animation that shares the update, such as the toast's: a web
    // view resized through an animation keeps its content offset from its view.
    .transaction(value: isPageFullScreen) { $0.animation = nil }
    .frame(width: size.width - narrow, height: size.height)
    .offset(x: push)
    // The Library is opaque over the sidebar and moves by its whole width, so its trailing edge stays the
    // sidebar's width short of the page's and the sidebar shows between them.
    if let library = store.scope(state: \.library, action: \.library.presented) {
      let x = -(1 - shown) * open
      LibraryView(store: library, window: store)
        .frame(width: open, height: size.height)
        .background { covering(background, window: size, at: x) }
        .offset(x: x)
        .allowsHitTesting(shown > 0)
    }
  }

  // How much of the Library is in, 0 to 1; a swipe sets it directly, so it follows the fingers.
  private func libraryShown(span: CGFloat) -> CGFloat {
    let slide = (store.sidebar.swipe ?? 0) * WindowFeature.libraryGain / span
    if store.isLibraryOpen { return max(1 + min(slide, 0), 0) }
    return store.spaces.selectedID == store.spaces.spaces.first?.id ? min(max(slide, 0), 1) : 0
  }

  private func backdrop(_ background: LinearGradient) -> some View {
    let theme = themePreview ?? store.spaces.selected.theme
    return background.opacity(store.isIncognito ? 1 : theme.opacity)
      .background(WindowBlur())
      .overlay { Grain(amount: store.isIncognito ? 0 : theme.grain) }
  }

  // The window's backdrop behind a view this far from the window's leading edge, so it hides the sidebar below.
  // Clipping hides the rest of it but leaves it hit-testable, so it must not take the sidebar's clicks.
  private func covering(_ background: LinearGradient, window: CGSize, at x: CGFloat) -> some View {
    Color.clear.overlay(alignment: .topLeading) {
      backdrop(background).frame(width: window.width, height: window.height).offset(x: -x)
    }
    .clipped()
    .allowsHitTesting(false)
  }

  // While the Library shows, the page is pushed this far right; the sidebar keeps its place and fades in only as
  // the Library leaves it.
  @ViewBuilder private func browser(
    isFloating: Bool, background: LinearGradient, library: (shown: CGFloat, push: CGFloat)
  ) -> some View {
    let theme = themePreview ?? store.spaces.selected.theme
    HStack(spacing: 0) {
      if !isFloating, !isPageFullScreen {
        SidebarView(store: store)
          .frame(width: store.sidebar.width)
          .overlay(alignment: .trailing) { resizeHandle }
          .opacity(pow(1 - Double(library.shown), 4))
          .offset(x: -library.push)
          .transition(.move(edge: .leading))
          // Above the page, so a space dot's tooltip reaches over it.
          .zIndex(1)
      }
      ContentArea(store: store, isThemed: !theme.colors.isEmpty)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DownloadThrows.space)) } action: {
          downloadThrows.page = $0
        }
        // The zoom indicator shares the corner with the find bar, which stays on top of it.
        .overlay(alignment: .topTrailing) {
          if let percent = store.zoomIndicator {
            // Flush with the card's corner.
            ZoomIndicator(percent: percent, theme: theme, isIncognito: store.isIncognito)
          }
        }
        .overlay(alignment: .topTrailing) {
          if let find = store.scope(state: \.find, action: \.find.presented) {
            // Shot 51: 10 pt below the developer toolbar, not over it.
            let space = store.spaces.selected
            let isUnderToolbar =
              space.selectedTab.map { $0.url.isDeveloperPage && space.split(of: $0.id) == nil } == true
            FindBar(store: find).padding(10).padding(.top, isUnderToolbar ? DeveloperBar.height : 0)
          }
        }
        .padding([.top, .bottom, .trailing], isPageFullScreen ? 0 : 10)
        .padding(.leading, isFloating && !isPageFullScreen ? 10 : 0)
    }

    if isFloating, !isPageFullScreen {
      Color.clear
        .frame(width: 10)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        // The card shows its first frame 2.6-3.4 frames after the pointer reaches the edge, which the hover and the
        // first frame take on their own, so there is no dwell.
        .onHover { isAtEdge in
          if isAtEdge { store.send(.sidebar(.peek(true))) }
        }
      // A permission prompt hangs off the URL pill, so it brings the sidebar out.
      if store.sidebar.isPeeking
        || store.spaces.selected.selectedTabID.flatMap({ Engine.shared.permissionRequests[$0] }) != nil
      {
        SidebarView(store: store)
          .frame(width: store.sidebar.visibleWidth)
          .frame(maxHeight: .infinity)
          // Translucent, so the page shows through; light themes stay nearly opaque so the page does not tint them.
          .background(background.opacity(Theme.isLight(theme) ? 0.95 : 0.8), in: RoundedRectangle(cornerRadius: 10))
          // The shadow follows the card's shape, so the sidebar's contents need no offscreen pass.
          .background(.regularMaterial.shadow(.drop(color: .black.opacity(0.4), radius: 12)), in: RoundedRectangle(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.floatingRim))
          .padding(6)
          // Entering matters too: a drag that left the sidebar and came back keeps it out. A pointer resting at
          // the window's edge is uncovered while the card overshoots past rest, and that is no exit.
          .onHover { over in
            if !over, let x = NSApp.currentEvent?.locationInWindow.x, (0...12).contains(x) { return }
            store.send(.sidebar(.peek(over)))
          }
          .transition(.move(edge: .leading))
          // Stays above the page while it slides out, too.
          .zIndex(1)
      }
    }
  }

  // A page in element full screen fills the window alone.
  private var isPageFullScreen: Bool {
    store.spaces.selected.selectedTabID.flatMap { Engine.shared.fullScreenPages[$0] } != nil
  }

  // The sidebar resizes by dragging its trailing edge.
  private var resizeHandle: some View {
    Color.clear
      .frame(width: 5)
      .contentShape(Rectangle())
      .pointerStyle(.columnResize)
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
          .onChanged { value in
            let start = resizeStart ?? store.sidebar.width
            resizeStart = start
            store.send(.sidebar(.resize(start + value.translation.width)))
          }
          .onEnded { _ in resizeStart = nil }
      )
  }
}

struct WebView: View {
  let view: NSView
  // Below a toolbar only the bottom corners are round.
  var roundsTop = true
  var cornerRadius = 6.0
  var onMouseDown: (() -> Void)?
  @State private var host = Host()
  @Environment(\.displayScale) private var scale

  var body: some View {
    PageHost(view: view, roundsTop: roundsTop, cornerRadius: cornerRadius, onMouseDown: onMouseDown, host: host)
      // The layout's width, not the animated frame's: the width the page comes to rest at, with its edges on the pixel
      // grid as the container's frame will have them. It arrives a few milliseconds before the container's own frame,
      // which applies it, so a drag resizes the engine once per step, not twice.
      .onGeometryChange(for: CGFloat.self) { proxy in
        let frame = proxy.frame(in: .global)
        return ((frame.maxX * scale).rounded() - (frame.minX * scale).rounded()) / scale
      } action: { host.container?.restingWidth = $0 }
  }

  final class Host {
    weak var container: WebContainer?
  }
}

private struct PageHost: NSViewRepresentable {
  let view: NSView
  let roundsTop: Bool
  let cornerRadius: Double
  let onMouseDown: (() -> Void)?
  let host: WebView.Host

  func makeNSView(context: Context) -> WebContainer {
    let container = WebContainer()
    host.container = container
    container.wantsLayer = true
    container.layer?.masksToBounds = true
    return container
  }

  func updateNSView(_ container: WebContainer, context: Context) {
    container.layer?.cornerRadius = cornerRadius
    container.layer?.maskedCorners =
      roundsTop ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
      : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    container.onMouseDown = onMouseDown
    // A page moving between places (a Peek closing, a split forming) belongs to the newest container;
    // older ones take it back only once it is free.
    guard container.page !== view, context.coordinator.isNew || view.superview == nil || view.superview === container
    else { return }
    context.coordinator.isNew = false
    // The page leaving the container is kept as it looked, for the tab switcher.
    container.page.map { Engine.shared.captureThumbnail(of: $0) }
    view.autoresizingMask = []
    container.show(view)
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  static func dismantleNSView(_ container: WebContainer, coordinator: Coordinator) {
    // A page whose container goes (a new tab's page is not made yet) is kept as it looked, for the tab switcher.
    container.page.map { Engine.shared.captureThumbnail(of: $0) }
    container.subviews = []
  }

  final class Coordinator {
    var isNew = true
  }
}

// Reports clicks in the page, which the page's own view takes.
final class WebContainer: NSView {
  var onMouseDown: (() -> Void)?
  // Watches a clear page (a WebKit page before its first paint) for the moment it shows.
  private var clearPage: NSKeyValueObservation?
  // Counts the display's frames once the clear page shows, until the page under it can leave.
  private var framesShown: CADisplayLink?
  private var frameCount = 0
  // Set as the layout changes, before the card's animated frame. A wider page is applied at once, so a ⌘S hide has it
  // drawn behind the card's clip before its motion starts; a narrower one waits for the card's first moving frame.
  var restingWidth: CGFloat? {
    didSet { if let restingWidth, restingWidth > bounds.width { fitPage() } }
  }
  private var monitor: Any?

  override func resizeSubviews(withOldSize oldSize: NSSize) { fitPage() }

  // The page shown, on top.
  var page: NSView? { subviews.last }

  // Shows the tab's page in place of the one before it, which stays underneath, as it looks, while the new page is
  // clear, so a switch between the tab's pages shows no empty frame; the new page takes the clicks.
  func show(_ view: NSView) {
    framesShown?.invalidate()
    framesShown = nil
    let showing = subviews.last { $0.alphaValue > 0 && $0 !== view }
    subviews = [view.alphaValue == 0 ? showing : nil, view].compactMap { $0 }
    fitPage()
    clearPage = subviews.count > 1
      ? view.observe(\.alphaValue) { [weak self] _, _ in MainActor.assumeIsolated { self?.uncover() } } : nil
  }

  // The page underneath leaves the window once the display has shown the new page over it. Out of the window, a
  // Chromium page blanks its content in its GPU process at once, which reaches the screen before the window's own
  // frame with the new page whenever that frame is late, as the first one of a new WebKit page is; the second frame
  // after the new page shows has it on the screen.
  private func uncover() {
    guard let page, page.alphaValue > 0 else { return }
    clearPage = nil
    frameCount = 0
    framesShown = displayLink(target: self, selector: #selector(frameShown(_:)))
    framesShown?.add(to: .main, forMode: .common)
  }

  @objc private func frameShown(_ link: CADisplayLink) {
    frameCount += 1
    guard frameCount == 2 else { return }
    link.invalidate()
    framesShown = nil
    subviews = page.map { [$0] } ?? []
  }

  // The page takes the width it comes to rest at, pinned to the card's leading edge and clipped by the card, so a ⌘S
  // lays the engine out once and its new layout lands mid-slide. On a show the narrower page moves with
  // the edge and the card is wider than it until the motion ends; that strip shows the page's own background
  // color, which the engine keeps on its view's backing layer. Before the layout has reported, the page fills the card.
  func fitPage() {
    for view in subviews {
      view.frame = NSRect(x: 0, y: 0, width: restingWidth ?? bounds.width, height: bounds.height)
    }
    layer?.backgroundColor = page?.subviews.first?.layer?.backgroundColor
  }

  override func viewDidMoveToWindow() {
    monitor.map(NSEvent.removeMonitor)
    monitor = nil
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      // Only a click that reaches the page, not one on a Peek or button over it.
      if let self, event.window == window, let frame = window?.contentView?.superview,
        frame.hitTest(frame.convert(event.locationInWindow, from: nil))?.isDescendant(of: self) == true
      {
        onMouseDown?()
      }
      return event
    }
  }
}

