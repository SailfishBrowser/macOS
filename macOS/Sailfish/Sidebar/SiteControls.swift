import ComposableArchitecture
import EngineCore
import SwiftUI

// The site controls popover on the URL pill: a dark card with share, capture and full-page capture tiles, the
// extensions' actions (none on a WebKit page), the site's settings and permissions, and its security with a "…" menu.
struct SiteControls: View {
  let space: Space
  let tab: Tab.ID
  let url: URL
  let open: (URL) -> Void
  @State private var revision = 0

  var body: some View {
    let _ = revision
    let page = Engine.shared.page(tab)
    let permissions = Engine.shared.sitePermissions(tab)
    let otherEngine = Engine.shared.otherEngine(tab)
    VStack(alignment: .leading, spacing: 0) {
      // Shot 57: 49 pt tiles 7 apart.
      HStack(spacing: 7) {
        ShareLink(item: url) { tile("square.and.arrow.up") }.help("Share")
        Button(action: capture) { tile("camera") }.help("Capture")
        tile("text.viewfinder").opacity(0.4).allowsHitTesting(false).accessibilityHidden(true)
      }
      .buttonStyle(.plain)
      if Engine.shared.shownEngine(tab) != .webkit {
        header("Extensions")
        // Four tiles a row; past three rows the grid scrolls.
        let actions = Engine.shared.extensionActions(tab, in: space)
        ScrollView {
          LazyVGrid(columns: Array(repeating: GridItem(.fixed(49), spacing: 7), count: 4), alignment: .leading, spacing: 7) {
            ForEach(actions, id: \.id) { item in
              ActionTile(item: item) { Engine.shared.runExtensionAction(item.id, tab, in: space) }
            }
            // Shot 57: the add tile is a light one, white 5% over the popover.
            Button { open(URL(string: "https://chromewebstore.google.com")!) } label: { tile("plus", fill: .white.opacity(0.05)) }
              .buttonStyle(.plain)
              .help("Add Extension")
          }
        }
        .frame(height: CGFloat(min((actions.count + 1 + 3) / 4, 3)) * 37 - 7)
        .scrollDisabled(actions.count + 1 <= 12)
      }
      header("Settings")
      // Developer mode follows the page's URL, so its row reports and does not toggle.
      setting("hammer.fill", "Developer Mode", url.isDeveloperPage ? "On" : "Off", isOn: url.isDeveloperPage)
        .allowsHitTesting(false)
      setting("gearshape.fill", "Automatic Picture-In-Picture", nil, isOn: false).opacity(0.4).allowsHitTesting(false)
        .accessibilityHidden(true)
      ForEach(permissions.keys.sorted(), id: \.self) { key in
        let allowed = permissions[key]!
        let permission = Engine.permissions[key]
        Button {
          Engine.shared.setSitePermission(tab, key, allowed: !allowed)
          revision += 1
        } label: {
          setting(permission?.symbol ?? "gearshape.fill", permission?.title ?? key, allowed ? "Allowed" : "Blocked", isOn: allowed)
        }
        .buttonStyle(.plain)
      }
      Divider().padding(.vertical, 8)
      HStack {
        let isSecure = page?.isSecure == true
        Label(isSecure ? "Secure" : "Not Secure", systemImage: isSecure ? "lock.fill" : "lock.open.fill")
          .font(.system(size: 13, weight: .medium))
          .padding(.horizontal, 8)
          .frame(height: 30)
          .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        Spacer()
        Menu {
          Button("Copy Link") { copyLink(url) }
          Button("Save Page…") { page?.savePage() }
          Button("Print…") { page?.printPage() }
          if let otherEngine {
            Divider()
            Button("Open Page in \(otherEngine.name)") { Task { await Engine.shared.reopen(tab, in: otherEngine) } }
          }
        } label: {
          Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.1), in: Circle())
            .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
      }
    }
    .foregroundStyle(.white)
    .padding(10)
    .frame(width: 236, alignment: .leading)
    .background(DarkPopover())
    .environment(\.colorScheme, .dark)
  }

  private func header(_ title: String) -> some View {
    Text(title).font(.system(size: 13, weight: .semibold)).padding(.top, 12).padding(.bottom, 8)
  }

  private func tile(_ systemName: String, fill: Color = .black.opacity(0.6)) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 14))
      .frame(width: 49, height: 30)
      .background(fill, in: RoundedRectangle(cornerRadius: 7))
      .contentShape(Rectangle())
  }

  // A settings row: a round icon, the setting and its state. Shot 57: a dark glyph on a white circle while the
  // setting is on, on a translucent one while it is off; rows 42 pt apart.
  private func setting(_ systemName: String, _ title: String, _ status: String?, isOn: Bool) -> some View {
    HStack(spacing: 8) {
      Image(systemName: systemName)
        .font(.system(size: 13))
        .foregroundStyle(.black.opacity(isOn ? 0.75 : 0.45))
        .frame(width: 32, height: 32)
        .background(.white.opacity(isOn ? 0.94 : 0.3), in: Circle())
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        if let status {
          Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .padding(.vertical, 5)
  }

  // Copies the visible page as an image and keeps it in Media.
  private func capture() {
    guard let shown = space.tabs[id: tab], let page = Engine.shared.page(tab) else { return }
    page.snapshot { image in
      guard let image else { return }
      MainActor.assumeIsolated { Captures.keep(image, of: shown, in: space) }
      SoundEffect.play(.capture)
    }
  }
}

// The popover is dark whatever the window's theme; the popover's chrome follows its window's appearance.
private struct DarkPopover: NSViewRepresentable {
  func makeNSView(context: Context) -> DarkPopoverView { DarkPopoverView() }
  func updateNSView(_ view: DarkPopoverView, context: Context) {}
}

private final class DarkPopoverView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.appearance = NSAppearance(named: .darkAqua)
  }
}

// The URL pill's buttons once a page is loaded: the pinned extensions on hover, Reader View, Share Quote
// while text is selected, else Copy Link, and site controls.
struct PillControls: View {
  let space: Space
  let url: URL
  let isHovered: Bool
  // Copy Link and Site Controls show whenever the pointer is over the sidebar.
  let isSidebarHovered: Bool
  // Shows the "Copied Current URL" toast.
  let copied: () -> Void
  let open: (URL) -> Void
  @State private var isOpen = false
  @State private var anchor: NSView?
  @State private var popups: [String: ExtensionPopup] = [:]
  @Shared(.pinnedExtensions) private var pinned

  var body: some View {
    if let tab = space.selectedTabID, let page = Engine.shared.page(tab) {
      let quote = Engine.shared.selections[tab]
      // The pill icons are centered 28 pt apart.
      HStack(spacing: 12) {
        // A pinned extension's popup keeps the pinned buttons showing, so it stays beside its button.
        if isHovered || isOpen || popups.values.contains(where: \.isOpen) {
          let actions = Engine.shared.extensionActions(tab, in: space)
          ForEach((pinned[space.profileID] ?? []).compactMap { id in actions.first { $0.id == id } }, id: \.id) { item in
            ExtensionButton(
              item: item, run: { Engine.shared.runExtensionAction(item.id, tab, in: space) },
              popup: Binding(get: { popups[item.id] }, set: { popups[item.id] = $0 })
            ) { $0.frame(width: 16, height: 16) }
          }
        }
        // Reader View, as Safari's button in the address field, on a page with an article.
        if Engine.shared.readers[tab] != nil || Engine.shared.readerable.contains(tab) {
          icon("doc.plaintext") { Engine.shared.toggleReader(tab) }
            .help(Engine.shared.readers[tab] == nil ? "Show Reader View" : "Hide Reader View")
        }
        if let quote {
          icon("quote.bubble") { shareQuote(quote, page) }
            .help("Share Quote")
            .background(AnchorView(view: $anchor))
        } else if isSidebarHovered || isOpen {
          icon("link") {
            copyLink(url)
            copied()
          }
            .help("Copy Link")
        }
        if isSidebarHovered || isOpen {
          icon("slider.horizontal.2.square") { isOpen = true }
            .help("Site Controls")
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
              SiteControls(space: space, tab: tab, url: url, open: open)
            }
        }
      }
    }
  }

  private func icon(_ systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName).font(.system(size: 13)).frame(width: 16, height: 16).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // Shares the quote with a link that scrolls to and highlights it.
  private func shareQuote(_ quote: String, _ page: any TabPage) {
    guard let view = anchor else { return }
    page.linkToHighlight { link in
      guard let link else { return }
      MainActor.assumeIsolated {
        NSSharingServicePicker(items: ["“\(quote)”\n\(link.absoluteString)"])
          .show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
      }
    }
  }
}

private struct AnchorView: NSViewRepresentable {
  @Binding var view: NSView?

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { self.view = view }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}
