import AppKit
import ComposableArchitecture
import SwiftUI

// An email or event a favorite's preview lists, as read from the favorite's own signed-in page.
struct PreviewItem: Codable, Equatable, Identifiable {
  let id: String
  let title: String
  let subtitle: String
  // Where clicking it takes the favorite; an item without one is clicked in the favorite's page.
  let url: URL?
}

// The apps whose favorites have previews: their badge and hover card come from the favorite's page.
enum PreviewApp {
  case gmail, calendar

  init?(_ url: URL) {
    switch url.host() {
    case "mail.google.com": self = .gmail
    case "calendar.google.com": self = .calendar
    default: return nil
    }
  }

  // The minutes after midnight an event's "10am to 11:30am" covers; one ending past midnight runs on past 24 hours.
  static func span(_ time: String) -> Range<Int>? {
    guard
      let match = time.firstMatch(
        of: /(\d{1,2})(?::(\d{2}))?\s*([ap]m)?\s*(?:to|–|-)\s*(\d{1,2})(?::(\d{2}))?\s*([ap]m)/.ignoresCase())
    else { return nil }
    func minutes(_ hour: Substring, _ minute: Substring?, _ meridiem: Substring) -> Int {
      Int(hour)! % 12 * 60 + (meridiem.lowercased() == "pm" ? 720 : 0) + (minute.flatMap { Int($0) } ?? 0)
    }
    let start = minutes(match.1, match.2, match.3 ?? match.6)
    let end = minutes(match.4, match.5, match.6)
    return start..<(end > start ? end : end + 1440)
  }

  // Gmail's title starts "Inbox (3)" while the inbox has unread emails.
  static func unreadCount(_ title: String) -> Int? {
    title.firstMatch(of: /^[^-]*\(([\d,.]+)\)/).flatMap { Int($0.1.filter(\.isNumber)) }
  }

  // The items in an extractor's result; nil when the page did not match.
  static func items(_ json: String?) -> [PreviewItem]? {
    json.flatMap { try? JSONDecoder().decode([PreviewItem].self, from: Data($0.utf8)) }
  }

  // Runs synchronously in the page's isolated world, as the bridge awaits no promise. Gmail's unread emails come
  // from its Atom feed with the page's own session; Calendar's events today from the chips on screen.
  var extractor: String {
    switch self {
    case .gmail:
      """
      (() => {
        const account = location.pathname.match(/^\\/mail\\/u\\/\\d+/);
        if (!account) return null;
        const request = new XMLHttpRequest();
        request.open('GET', account[0] + '/feed/atom', false);
        request.send();
        if (request.status !== 200) return null;
        const feed = new DOMParser().parseFromString(request.responseText, 'application/xml');
        if (!feed.querySelector('feed')) return null;
        const text = (entry, selector) => entry.querySelector(selector)?.textContent.trim() ?? '';
        return JSON.stringify([...feed.querySelectorAll('entry')].slice(0, 6).map(entry => ({
          id: text(entry, 'id'), title: text(entry, 'author > name'), subtitle: text(entry, 'title'),
          url: entry.querySelector('link')?.getAttribute('href') || null
        })));
      })()
      """
    case .calendar:
      """
      (() => {
        if (!document.querySelector('[role="main"]')) return null;
        const today = new Date().toLocaleDateString('en-US', {month: 'long', day: 'numeric', year: 'numeric'});
        const items = [];
        const seen = new Set();
        for (const chip of document.querySelectorAll('[data-eventid]')) {
          const id = chip.getAttribute('data-eventid');
          if (seen.has(id)) continue;
          seen.add(id);
          const label = chip.getAttribute('aria-label') || chip.firstElementChild?.textContent || '';
          const [time, title] = label.split(', ').map(part => part.trim());
          if (title && label.includes(today)) items.push({id, title, subtitle: time, url: null});
        }
        return JSON.stringify(items);
      })()
      """
    }
  }

  // Clicks an item's element in the page, as for a Calendar event, which opens its details there.
  static func clickScript(_ item: PreviewItem) -> String {
    let id = String(data: try! JSONEncoder().encode(item.id), encoding: .utf8)!
    return "document.querySelector('[data-eventid=\"' + CSS.escape(\(id)) + '\"]')?.click(); null"
  }
}

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // The favorite menu toggles: Gmail's "Show Unread Badge" and Live Calendar's "Show Hover Preview".
  static var gmailUnreadBadge: Self { Self[.appStorage("gmailUnreadBadge"), default: true] }
  static var calendarHoverPreview: Self { Self[.appStorage("calendarHoverPreview"), default: true] }
}

// What each favorite's preview last read from its page, and when.
@MainActor @Observable
final class FavoritePreviews {
  static let shared = FavoritePreviews()
  var items: [Tab.ID: [PreviewItem]] = [:]
  var fetched: [Tab.ID: Date] = [:]

  func refresh(_ tab: Tab.ID, _ app: PreviewApp) {
    Engine.shared.tabs[tab]?.evaluateJavaScript(app.extractor) { json in
      MainActor.assumeIsolated {
        guard let items = PreviewApp.items(json) else { return }
        self.items[tab] = items
        self.fetched[tab] = .now
      }
    }
  }

  func click(_ item: PreviewItem, in tab: Tab.ID) {
    Engine.shared.tabs[tab]?.evaluateJavaScript(PreviewApp.clickScript(item)) { _ in }
  }
}

// The hover card: dark, with no arrow, its top left corner on the tile's bottom right one.
struct FavoritePreviewCard: View {
  static let width: CGFloat = 240
  let tab: Tab.ID
  let app: PreviewApp
  let items: [PreviewItem]
  // Opens an item in the favorite, or a new Calendar event.
  let open: (PreviewItem) -> Void

  var body: some View {
    Group {
      switch app {
      case .gmail where items.isEmpty:
        Text("No unread emails")
          .font(.system(size: 13))
          .foregroundStyle(.white.opacity(0.87))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
      case .gmail:
        VStack(spacing: 0) {
          ForEach(items.prefix(6)) { item in PreviewRow(item: item) { open(item) } }
        }
        .padding(6)
      case .calendar:
        CalendarDay(tab: tab, items: items, open: open)
      }
    }
    .frame(width: Self.width)
    .background(
      LinearGradient(colors: [Color(hex: 0x29292B), Color(hex: 0x1F1F20)], startPoint: .topLeading, endPoint: .bottomTrailing),
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.2), lineWidth: 1))
    .environment(\.colorScheme, .dark)
  }
}

private struct PreviewRow: View {
  let item: PreviewItem
  let open: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title).font(.system(size: 13, weight: .semibold))
        Text(item.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .background(isHovering ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}

// Live Calendar's card: today's hours from the current one, its events on them, a line at now, and its settings and
// new event buttons.
private struct CalendarDay: View {
  static let hourHeight: CGFloat = 42
  static let newEvent = URL(string: "https://calendar.google.com/calendar/r/eventedit")!
  let tab: Tab.ID
  let items: [PreviewItem]
  @Shared(.calendarHoverPreview) private var showsHoverPreview
  let open: (PreviewItem) -> Void

  var body: some View {
    TimelineView(.everyMinute) { context in
      let calendar = Calendar.current
      let first = calendar.component(.hour, from: context.date) * 60
      let now = calendar.component(.minute, from: context.date)
      ZStack(alignment: .topLeading) {
        VStack(spacing: 0) {
          ForEach(0..<6, id: \.self) { row in
            VStack(alignment: .leading, spacing: 0) {
              Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
              Text(hour(first / 60 + row)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                .padding(.leading, 5).padding(.top, 6)
            }
            .frame(height: Self.hourHeight, alignment: .top)
          }
        }
        ForEach(items) { item in
          if let span = PreviewApp.span(item.subtitle), span.upperBound > first, span.lowerBound < first + 360 {
            Button { open(item) } label: {
              Text(item.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(hex: 0x4285F4).opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .frame(height: max(y(span.upperBound - first) - y(max(span.lowerBound - first, 0)) - 1, 16))
            .padding(.leading, 41).padding(.trailing, 6)
            .offset(y: y(max(span.lowerBound - first, 0)))
          }
        }
        HStack(spacing: 0) {
          Circle().frame(width: 6, height: 6)
          Rectangle().frame(height: 1.5)
        }
        .foregroundStyle(.white)
        .padding(.leading, 38).padding(.trailing, 6)
        .offset(y: y(now) - 3)
      }
      .padding(.top, 13)
    }
    .frame(height: 256, alignment: .top)
    .clipped()
    .overlay(alignment: .bottomTrailing) {
      HStack(spacing: 8) {
        circleButton("gearshape.fill", fill: 0x343434, action: settings)
        circleButton("plus", fill: 0x1E1E1E) { open(PreviewItem(id: "", title: "", subtitle: "", url: Self.newEvent)) }
      }
      .padding(10)
    }
  }

  private func circleButton(_ symbol: String, fill: UInt32, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85))
        .frame(width: 32, height: 32)
        .background(Color(hex: fill), in: Circle())
        .overlay(Circle().strokeBorder(.black.opacity(0.25)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
  }

  // The gear menu: when the page was last read, a refresh, and turning the card off.
  private func settings() {
    let menu = NSMenu()
    menu.autoenablesItems = false
    if let fetched = FavoritePreviews.shared.fetched[tab] {
      let item = NSMenuItem(
        title: "Last fetch: \(fetched.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))", action: nil,
        keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    menu.addItem(MenuAction.item("Refresh") { FavoritePreviews.shared.refresh(tab, .calendar) })
    menu.addItem(.separator())
    menu.addItem(MenuAction.item("Disable Live Calendar") { $showsHoverPreview.withLock { $0 = false } })
    PreviewPanel.isMenuOpen = true
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    PreviewPanel.isMenuOpen = false
  }

  private func y(_ minutes: Int) -> CGFloat {
    CGFloat(minutes) / 60 * Self.hourHeight
  }

  private func hour(_ hour: Int) -> String {
    let hour = hour % 24
    return "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
  }
}

// One card for the whole app, in a panel over the window so it can reach past the sidebar.
@MainActor
private enum PreviewPanel {
  static let panel: NSPanel = {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    return panel
  }()
  static var owner: Tab.ID?
  // The card stays while its gear menu is open over the page.
  static var isMenuOpen = false

  static func show(_ card: some View, for tab: Tab.ID, from tile: NSView) {
    guard let window = tile.window else { return }
    let host = NSHostingView(rootView: card)
    let size = host.fittingSize
    let corner = window.convertToScreen(tile.convert(tile.bounds, to: nil))
    panel.contentView = host
    panel.setFrame(NSRect(x: corner.maxX - 3, y: corner.minY + 3 - size.height, width: size.width, height: size.height), display: true)
    if panel.parent != window {
      panel.parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
    }
    panel.orderFront(nil)
    owner = tab
  }

  static func contains(_ point: NSPoint, for tab: Tab.ID) -> Bool {
    owner == tab && (isMenuOpen || panel.frame.contains(point))
  }

  static func hide(_ tab: Tab.ID) {
    guard owner == tab else { return }
    owner = nil
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }
}

// A menu item that runs a closure, which it keeps.
private final class MenuAction: NSObject {
  let run: () -> Void

  init(_ run: @escaping () -> Void) {
    self.run = run
  }

  @objc func fire() {
    run()
  }

  static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(run)
    let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
    item.target = action
    item.representedObject = action
    return item
  }
}

// The tile's view, which places the card.
private final class TileAnchor {
  weak var view: NSView?
}

private struct TileAnchorView: NSViewRepresentable {
  let anchor: TileAnchor

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    anchor.view = view
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

// A Gmail or Calendar favorite's badge and hover card, read from its page, which stays loaded for them.
private struct FavoritePreviewModifier: ViewModifier {
  let tab: Tab
  let preload: () -> Void
  let open: (PreviewItem) -> Void
  @Environment(\.isDragging) private var isDragging
  @Shared(.gmailUnreadBadge) private var gmailUnreadBadge
  @Shared(.calendarHoverPreview) private var calendarHoverPreview
  @State private var anchor = TileAnchor()
  @State private var isShown = false
  @State private var isTileHovered = false
  @State private var pending: Task<Void, Never>?

  private var app: PreviewApp? { PreviewApp(tab.pinnedURL ?? tab.url) }

  func body(content: Content) -> some View {
    content
      .background(TileAnchorView(anchor: anchor))
      .overlay(alignment: .bottomTrailing) {
        if app == .gmail, gmailUnreadBadge, (PreviewApp.unreadCount(tab.title) ?? 0) > 0 {
          Circle().fill(Color(hex: 0xD95140)).frame(width: 5, height: 5).padding(8)
        }
      }
      .onHover { isTileHovered = $0; hoverChanged() }
      .simultaneousGesture(TapGesture().onEnded { dismiss() })
      .onDisappear { dismiss() }
      .task(id: tab.isLive) {
        guard let app else { return }
        guard tab.isLive else { return preload() }
        // The page renders its list after loading, and then keeps it current.
        try? await Task.sleep(for: .seconds(3))
        while !Task.isCancelled {
          FavoritePreviews.shared.refresh(tab.id, app)
          try? await Task.sleep(for: .seconds(30))
        }
      }
  }

  // The card shows after half a second over the tile and stays while the pointer is on the tile or the card. The
  // card's panel never becomes key, so the pointer's place, not hover, tells whether it is on the card.
  private func hoverChanged() {
    guard let app, app == .gmail || calendarHoverPreview else { return }
    pending?.cancel()
    let isHovered = isTileHovered && !isDragging
    guard isHovered != isShown else { return }
    pending = Task {
      try? await Task.sleep(for: .seconds(isHovered ? 0.5 : 0.2))
      guard !Task.isCancelled, !isHovered || NSEvent.pressedMouseButtons == 0 else { return }
      guard isHovered else {
        while PreviewPanel.contains(NSEvent.mouseLocation, for: tab.id) {
          try? await Task.sleep(for: .seconds(0.1))
          if Task.isCancelled { return }
        }
        return dismiss()
      }
      FavoritePreviews.shared.refresh(tab.id, app)
      // Nothing to show until the page has been read, as when it is signed out.
      guard let items = FavoritePreviews.shared.items[tab.id], let tile = anchor.view else { return }
      let card = FavoritePreviewCard(tab: tab.id, app: app, items: items) { item in
        dismiss()
        open(item)
      }
      PreviewPanel.show(card, for: tab.id, from: tile)
      isShown = true
    }
  }

  private func dismiss() {
    pending?.cancel()
    isShown = false
    PreviewPanel.hide(tab.id)
  }
}

extension View {
  func favoritePreview(_ tab: Tab, preload: @escaping () -> Void, open: @escaping (PreviewItem) -> Void) -> some View {
    modifier(FavoritePreviewModifier(tab: tab, preload: preload, open: open))
  }
}

// Atop a Calendar favorite's menu: when its page was last read, a refresh and the hover card's toggle.
struct LiveCalendarMenu: View {
  let tab: Tab
  @Shared(.calendarHoverPreview) private var showsHoverPreview

  var body: some View {
    Menu {
      if let fetched = FavoritePreviews.shared.fetched[tab.id] {
        Button("Last fetch: \(fetched.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))") {}
          .disabled(true)
      }
      Button("Refresh") { FavoritePreviews.shared.refresh(tab.id, .calendar) }
      Divider()
      Toggle("Show Hover Preview", isOn: Binding($showsHoverPreview))
    } label: {
      if let favicon = tab.favicon {
        Label { Text("Live Calendar") } icon: { Image(nsImage: favicon) }
      } else {
        Text("Live Calendar")
      }
    }
  }
}

// Under a Gmail favorite's Share.
struct UnreadBadgeToggle: View {
  @Shared(.gmailUnreadBadge) private var showsBadge

  var body: some View {
    Toggle("Show Unread Badge", isOn: Binding($showsBadge))
  }
}
