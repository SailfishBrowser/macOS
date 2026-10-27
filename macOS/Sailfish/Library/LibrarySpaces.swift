import ComposableArchitecture
import SwiftUI

// The Library's Spaces: each space as a column card of its folders and pinned tabs, in its theme. A card's handle
// reorders the spaces; a tab dragged off a card goes to the card it is dropped on.
struct LibrarySpaces: View {
  let window: StoreOf<WindowFeature>
  // A card dragged by its handle, the order it makes, and how far it has moved.
  @State private var drag: (id: Space.ID, order: [Space.ID], dx: CGFloat)?
  // A tab dragged off its card, and where the pointer is.
  @State private var tabDrag: (tab: Tab, from: Space.ID, location: CGPoint)?
  @State private var frames: [Space.ID: CGRect] = [:]
  private let pitch: CGFloat = 240 + 24
  private static let space = "library-spaces"

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 24) {
        ForEach(spaces) { space in
          SpaceCard(
            window: window, space: space, profile: window.spaces.profiles[id: space.profileID]?.name,
            isTarget: tabDrag.map { target(at: $0.location) == space.id && $0.from != space.id } ?? false,
            move: DragGesture(minimumDistance: 2, coordinateSpace: .global)
              .onChanged { move(space.id, by: $0.translation.width) }
              .onEnded { _ in drop() },
            dragTab: { tab, value in tabDrag = (tab, space.id, value.location) },
            dropTab: dropTab
          )
          .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[space.id] = $0 }
          .offset(x: drag?.id == space.id ? offset : 0)
          .zIndex(drag?.id == space.id ? 1 : 0)
        }
      }
      .padding(.horizontal, 22)
      .padding(.vertical, 48)
    }
    .scrollIndicators(.never)
    .coordinateSpace(name: Self.space)
    .overlay(alignment: .topLeading) {
      // The dragged tab's row follows the pointer over the cards.
      if let tabDrag {
        TabLabel(tab: tabDrag.tab)
          .padding(.horizontal, 12).frame(height: 36)
          .background(Theme.menu.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
          .foregroundStyle(.white)
          .offset(x: tabDrag.location.x - 20, y: tabDrag.location.y - 18)
          .allowsHitTesting(false)
      }
    }
  }

  private var spaces: [Space] {
    drag.map { $0.order.compactMap { window.spaces.spaces[id: $0] } } ?? window.spaces.spaces.elements
  }

  // The dragged card's distance from the slot it now holds.
  private var offset: CGFloat {
    guard let drag, let start = window.spaces.spaces.index(id: drag.id) else { return 0 }
    return drag.dx - CGFloat(drag.order.firstIndex(of: drag.id)! - start) * pitch
  }

  // The other cards slide aside while a card is dragged by its handle.
  private func move(_ id: Space.ID, by dx: CGFloat) {
    let start = window.spaces.spaces.index(id: id)!
    var order = window.spaces.spaces.ids.elements.filter { $0 != id }
    let index = min(max(Int((CGFloat(start) + dx / pitch).rounded()), 0), order.count)
    order.insert(id, at: index)
    withAnimation(order != drag?.order ? Motion.layout : nil) { drag = (id, order, dx) }
  }

  private func drop() {
    guard let drag else { return }
    withAnimation(Motion.layout) {
      self.drag = nil
      window.send(.spaces(.moveSpace(drag.id, to: drag.order.firstIndex(of: drag.id)!)))
    }
  }

  private func target(at location: CGPoint) -> Space.ID? {
    frames.first { $0.value.contains(location) }?.key
  }

  // A tab dropped on another card, empty or not, moves to that space; anywhere else it stays.
  private func dropTab() {
    guard let tabDrag else { return }
    self.tabDrag = nil
    guard let target = target(at: tabDrag.location), target != tabDrag.from else { return }
    window.send(.spaces(.moveTab(tabDrag.tab.id, from: tabDrag.from, to: target)), animation: Motion.layout)
  }
}

private struct SpaceCard: View {
  let window: StoreOf<WindowFeature>
  let space: Space
  let profile: String?
  let isTarget: Bool
  let move: _EndedGesture<_ChangedGesture<DragGesture>>
  let dragTab: (Tab, DragGesture.Value) -> Void
  let dropTab: () -> Void
  @State private var isPickingIcon = false
  @State private var isClearHovered = false

  var body: some View {
    let today = space.tabs(in: .unpinned)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        if !space.icon.isEmpty {
          SpaceIcon(icon: space.icon)
        }
        Text(space.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 0)
        if let profile {
          Label(profile, systemImage: "face.smiling").font(.system(size: 11)).lineLimit(1)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 7).frame(height: 20)
            .background(Theme.fill, in: Capsule())
            .fixedSize()
        }
        // As in the sidebar, the paintbrush opens the space's theme editor.
        if !window.isIncognito {
          button("paintbrush.pointed", help: "Edit Theme", action: edit)
        }
      }
      .padding(.leading, 16).padding(.trailing, 10)
      .frame(height: 50)
      // The card's title row has the same menu as its "…" button.
      .contentShape(Rectangle())
      .contextMenu { spaceMenu }
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(space.rows(in: .pinned)) { item in
            switch item {
            case let .folder(folder):
              row(folder.name, weight: .semibold) { FolderGlyph(isOpen: false, accent: Theme.accent(space.theme)) }
                .onTapGesture { open(nil) }
            case let .tab(tab):
              tabRow(tab)
            }
          }
          if !today.isEmpty {
            HStack(spacing: 8) {
              Rectangle().fill(Theme.divider).frame(height: 1)
              Button { window.send(.tab(.clearToday, in: space.id), animation: Motion.row) } label: {
                Text("↓ Clear").font(.system(size: 11, weight: .semibold))
                  .foregroundStyle(isClearHovered ? Theme.primaryText : Theme.secondaryText)
              }
              .buttonStyle(.plain)
              .onHover { isClearHovered = $0 }
            }
            .padding(.horizontal, 16)
            .frame(height: 20)
            ForEach(today) { tabRow($0) }
          }
        }
      }
      .scrollIndicators(.never)
      HStack {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Theme.secondaryText)
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
          .gesture(move)
        Spacer()
        Menu { spaceMenu } label: {
          Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.secondaryText)
            .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $isPickingIcon, arrowEdge: .bottom) {
          IconPicker(icon: Binding { space.icon } set: { icon in
            window.send(.spaces(.update(space.id, name: space.name, icon: icon, theme: space.theme)))
          })
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    }
    .foregroundStyle(Theme.primaryText)
    .frame(width: 240)
    .background(LinearGradient(theme: space.theme), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white, lineWidth: isTarget ? 2 : 0))
    .environment(\.colorScheme, Theme.isLight(space.theme) ? .light : .dark)
    .contentShape(Rectangle())
    .onTapGesture { open(nil) }
  }

  private var spaceMenu: some View {
    SpaceMenu(
      store: window, space: space,
      changeIcon: { isPickingIcon = true },
      editTheme: edit,
      newFolder: { window.send(.tab(.newFolder(in: .pinned, with: []), in: space.id), animation: Motion.row) },
      shareAnchor: {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return nil }
        return NSRect(origin: view.convert(window.mouseLocationOutsideOfEventStream, from: nil), size: .zero)
      })
  }

  private func open(_ tab: Tab.ID?) {
    window.send(.openFromLibrary(space.id, tab: tab))
  }

  private func edit() {
    open(nil)
    window.send(.sidebar(.editSpace(creating: false)))
  }

  // A click opens the tab in its space; a drag takes it to another card.
  private func tabRow(_ tab: Tab) -> some View {
    row(tab.displayTitle, weight: .regular) { TabFavicon(tab: tab, space: space).frame(width: 16, height: 16) }
      .onTapGesture { open(tab.id) }
      .gesture(
        DragGesture(minimumDistance: 4, coordinateSpace: .named("library-spaces"))
          .onChanged { dragTab(tab, $0) }
          .onEnded { _ in dropTab() })
  }

  private func row<Icon: View>(_ title: String, weight: Font.Weight, @ViewBuilder icon: () -> Icon) -> some View {
    HStack(spacing: 10) {
      icon().frame(width: 19)
      Text(title).font(.system(size: 14, weight: weight)).lineLimit(1)
    }
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, minHeight: 41, alignment: .leading)
    .contentShape(Rectangle())
  }

  private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
        .frame(width: 24, height: 24).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}

// A tab's favicon and title, as the dragged copy shows them.
private struct TabLabel: View {
  let tab: Tab

  var body: some View {
    HStack(spacing: 10) {
      (tab.favicon.map(Image.init(nsImage:)) ?? Image(systemName: "globe")).resizable().aspectRatio(contentMode: .fit)
        .frame(width: 16, height: 16)
      Text(tab.displayTitle).font(.system(size: 14)).lineLimit(1)
    }
  }
}
