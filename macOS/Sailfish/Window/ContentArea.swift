import ComposableArchitecture
import SwiftUI

// The page area: the selected tab, or its split view's panes, with Peek over them.
struct ContentArea: View {
  let store: StoreOf<WindowFeature>
  let isThemed: Bool
  @State private var peek: WindowFeature.Peek?
  @State private var peekProgress = 0.0
  // The page shows only while Peek is full size, as a web view's frame cannot animate.
  @State private var showsPeekPage = false

  private var space: Space { store.spaces.selected }
  private var accent: Color { store.isIncognito ? Theme.accent : Theme.accent(space.theme) }

  var body: some View {
    Group {
      let split = space.split(of: space.selectedTabID)
      if let selected = space.selectedTabID {
        // One layout for a split and a lone page, so a pane closed from a split keeps the other page's view: it
        // takes the card the next frame. Expand Current Split shows the focused pane alone, still
        // with its pane bar; a page in element full screen shows alone without it.
        let isFullScreen = Engine.shared.fullScreenPages[selected] != nil
        let expanded = split != nil && store.expandedPane == selected || isFullScreen
        SplitPanes(
          store: store, tabIDs: expanded ? [selected] : split?.tabIDs ?? [selected],
          widths: expanded || split == nil ? [1] : split!.widths, isVertical: split?.isVertical == true,
          isSplit: split != nil && !isFullScreen, accent: accent, isThemed: isThemed)
      } else {
        Pane(store: store, tab: nil, accent: accent, isThemed: isThemed, isSplit: false)
      }
    }
    .overlay {
      if let peek {
        PeekOverlay(store: store, peek: peek, progress: peekProgress, showsPage: showsPeekPage)
      }
    }
    // In the strip above the card.
    .overlay(alignment: .top) {
      if let tab = space.selectedTab {
        LoadBar(tab: tab).offset(y: -7)
      }
    }
    // Peek grows from the link and shrinks back there, on the layout curve.
    .onChange(of: store.peek) { old, new in
      if let new {
        peek = new
        if old == nil {
          peekProgress = 0
          // Grows once the card is in place at the link, a turn after it is inserted.
          DispatchQueue.main.async {
            withAnimation(Motion.layout) { peekProgress = 1 } completion: { showsPeekPage = store.peek != nil }
          }
        }
      } else {
        showsPeekPage = false
        withAnimation(Motion.layout) { peekProgress = 0 } completion: { peek = nil }
      }
    }
  }
}

private struct SplitPanes: View {
  let store: StoreOf<WindowFeature>
  let tabIDs: [Tab.ID]
  let widths: [Double]
  let isVertical: Bool
  let isSplit: Bool
  let accent: Color
  let isThemed: Bool
  // Shot 65: the cards are 10 pt apart.
  private let gutter = 10.0

  var body: some View {
    GeometryReader { proxy in
      let vertical = isVertical
      let available = (vertical ? proxy.size.height : proxy.size.width) - gutter * Double(tabIDs.count - 1)
      let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
      // A lone page keeps one pane as its tab changes, so the page it replaces stays under a WebKit page until that
      // one has drawn; a split's panes follow their tabs.
      let keys = tabIDs.count == 1 ? [nil] : tabIDs.map(Optional.some)
      layout {
        ForEach(Array(keys.enumerated()), id: \.element) { index, _ in
          let id = tabIDs[index]
          if index > 0 {
            divider(index - 1, available)
          }
          let share = available * widths[index]
          Pane(store: store, tab: store.spaces.selected.tabs[id: id], accent: accent, isThemed: isThemed, isSplit: isSplit)
            .frame(width: vertical ? nil : share, height: vertical ? share : nil)
        }
      }
      .coordinateSpace(.named("split"))
    }
  }

  // The gutter between two panes, dragged across the split to resize them.
  private func divider(_ index: Int, _ available: Double) -> some View {
    let vertical = isVertical
    return Color.clear
      .frame(width: vertical ? nil : gutter, height: vertical ? gutter : nil)
      .contentShape(Rectangle())
      .onHover { $0 ? (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() : NSCursor.pop() }
      .gesture(
        DragGesture(coordinateSpace: .named("split")).onChanged { value in
          guard let split = store.spaces.selected.split(of: tabIDs[index]) else { return }
          let location = vertical ? value.location.y : value.location.x
          let position = (location - gutter * (Double(index) + 0.5)) / available
          store.send(.tab(.resizeSplit(split.id, divider: index, position: position), in: store.spaces.selectedID))
        }
      )
  }
}

private struct Pane: View {
  let store: StoreOf<WindowFeature>
  let tab: Tab?
  let accent: Color
  let isThemed: Bool
  let isSplit: Bool
  // The page as a still while the Library is open or a swipe brings it in: a web view's frame cannot animate,
  // and the still rides along in the card at the window's edge. The page stays in the window under it, so it is drawn
  // when the still goes; a WebKit page out of the window would be clear until it had drawn again.
  @State private var still: NSImage?

  private var space: Space { store.spaces.selected }

  private var isFullScreen: Bool { tab.map { Engine.shared.fullScreenPages[$0.id] != nil } == true }

  private var isFrozen: Bool {
    store.isLibraryOpen
      || (store.sidebar.swipe ?? 0) > 0 && store.spaces.selectedID == store.spaces.spaces.first?.id
  }

  // A picked theme shows through the card, lightened.
  private var fill: AnyShapeStyle {
    store.isIncognito
      ? AnyShapeStyle(Theme.incognitoCard) : isThemed ? AnyShapeStyle(.white.opacity(0.1)) : AnyShapeStyle(Theme.card)
  }

  var body: some View {
    RoundedRectangle(cornerRadius: 6)
      .fill(fill)
      // The card shadow: a Gaussian of sigma 3.1 pt, fitted as 1.75 pt at radius 2.
      .shadow(color: .black.opacity(0.25), radius: 3.5, y: 1)
      .overlay {
        VStack(spacing: 0) {
          bar
          page.frame(maxWidth: .infinity, maxHeight: .infinity).overlay(alignment: .bottomLeading) {
            if let tab { LinkBubbleOverlay(tab: tab.id, accent: accent) }
          }
        }
      }
      .overlay {
        if isSplit, tab?.id == space.selectedTabID {
          RoundedRectangle(cornerRadius: 6).strokeBorder(accent, lineWidth: 1)
        }
      }
  }

  @ViewBuilder private var bar: some View {
    if let tab, tab.url.isDeveloperPage, !isFullScreen {
      DeveloperBar(tab: tab, accent: accent, close: isSplit ? { close() } : nil) { store.send(.editSelectedTab) }
    } else if let tab, isSplit {
      let panes = space.split(of: tab.id)?.tabIDs ?? [tab.id]
      PaneBar(
        tab: tab, space: space, isFocused: tab.id == space.selectedTabID, panes: panes,
        isExpanded: store.expandedPane == tab.id, act: { act($0) },
        open: { store.send(.tab(.open($0), in: space.id)) }, split: { split() }, close: { close() },
        edit: {
          select()
          store.send(.editSelectedTab)
        },
        expand: {
          select()
          store.send(.toggleExpandedPane)
        }
      )
      .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
    } else if let tab, store.showsURLToolbar, !isFullScreen {
      URLToolbar(url: tab.url) { store.send(.editSelectedTab) }
    }
  }

  @ViewBuilder private var page: some View {
    let hasBar = tab.map { isSplit || ($0.url.isDeveloperPage || store.showsURLToolbar) && !isFullScreen } ?? false
    ZStack {
      if let tab, let view = Engine.shared.view(tab.id) {
        WebView(view: view, roundsTop: !hasBar, cornerRadius: isFullScreen ? 0 : 6, onMouseDown: { select() })
      } else if let tab {
        // A tab a space switch selected gets its page once the strip settles; until then the card names it.
        PagePlaceholder(tab: tab, space: space)
      }
      if let still {
        Image(nsImage: still).resizable().scaledToFill()
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .clipShape(
            UnevenRoundedRectangle(
              topLeadingRadius: hasBar ? 0 : 6, bottomLeadingRadius: 6, bottomTrailingRadius: 6,
              topTrailingRadius: hasBar ? 0 : 6))
      }
      if let tab {
        ReaderOverlay(tab: tab.id, url: tab.url)
        PageDialogOverlay(tab: tab.id)
      }
    }
    .task(id: Frozen(isFrozen: isFrozen, tab: tab?.id)) {
      guard isFrozen else {
        // The still stays through the Library's closing motion, then the live page returns.
        guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
        still = nil
        return
      }
      guard still == nil, let tab, let page = Engine.shared.page(tab.id) else { return }
      page.snapshot { still = $0 }
    }
  }

  // A lone pane's tab changes under it, and a still is of one tab.
  private struct Frozen: Equatable {
    let isFrozen: Bool
    let tab: Tab.ID?
  }

  private func select() {
    guard let tab, tab.id != space.selectedTabID else { return }
    store.send(.tab(.select(tab.id), in: space.id))
  }

  private func act(_ action: TabsFeature.Action) {
    select()
    store.send(.tab(action, in: space.id))
  }

  // A pane's split button: the New Split command bar, whose page opens beside this pane.
  private func split() {
    select()
    store.send(.newSplit)
  }

  // A pinned tab leaves the split and resets.
  private func close() {
    guard let tab else { return }
    store.send(.tab(.close(tab.id), in: space.id))
  }
}

// The selected tab's favicon and title, in the card before its page exists.
private struct PagePlaceholder: View {
  let tab: Tab
  let space: Space

  var body: some View {
    VStack(spacing: 10) {
      TabFavicon(tab: tab, space: space)
      Text(tab.displayTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondaryText).lineLimit(1)
    }
    .padding(.horizontal, 40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// The engine's hovered link and open dialog are read here, in their own views, so a link hover or a dialog
// re-evaluates the overlay alone and not the pane holding the web view.
private struct LinkBubbleOverlay: View {
  let tab: Tab.ID
  let accent: Color

  var body: some View {
    if let link = Engine.shared.hoveredLinks[tab] {
      LinkBubble(url: link, accent: accent)
    }
  }
}

private struct PageDialogOverlay: View {
  let tab: Tab.ID

  var body: some View {
    if let dialog = Engine.shared.dialogs[tab] {
      PageDialogView(dialog: dialog).id(dialog.id).clipShape(RoundedRectangle(cornerRadius: 6))
    }
  }
}
