import AppKit
import SwiftUI

// A split view in the sidebar: one row with a tab per half, parted by a hairline; selected, the halves become
// chips with the focused one lit. A hovered chip shows an X, which closes its pane, or with ⌥ separates it.
struct SplitRow<Menu: View>: View {
  let tabs: [Tab]
  let space: Space
  let act: (TabsFeature.Action) -> Void
  @ViewBuilder let menu: (Tab) -> Menu
  @State private var isHovering = false
  @State private var hoveredChip: Tab.ID?

  var body: some View {
    let isSelected = tabs.contains { $0.id == space.selectedTabID }
    HStack(spacing: isSelected ? 4 : 0) {
      ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
        if index > 0, !isSelected {
          Rectangle().fill(Theme.divider).frame(width: 1).padding(.vertical, 6)
        }
        HStack(spacing: 8) {
          TabFavicon(tab: tab, space: space).frame(width: 16).engineMark(tab)
          Text(tab.displayTitle).foregroundStyle(Theme.rowText)
          if hoveredChip == tab.id {
            Spacer(minLength: 0)
            Button {
              act(NSEvent.modifierFlags.contains(.option) ? .separate(tab.id) : .close(tab.id))
            } label: {
              Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.icon)
                .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .font(.system(size: 14))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
          !isSelected ? .clear : tab.id == space.selectedTabID ? Theme.selection : Theme.fill,
          in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hoveredChip = $0 ? tab.id : hoveredChip == tab.id ? nil : hoveredChip }
        .onTapGesture { act(.select(tab.id)) }
        .contextMenu {
          menu(tab)
          Divider()
          Button("Separate Page from Split View") { act(.separate(tab.id)) }
          Button("Separate All Tabs") { space.split(of: tab.id).map { act(.separateAll($0.id)) } }
        }
      }
    }
    .padding(3)
    .frame(height: 36)
    // The shadow follows the fill's shape, not the panes' contents, so it needs no offscreen pass.
    .background(
      (isSelected ? Theme.rowSelection(space.theme) : isHovering ? Theme.rowHover : .clear)
        .shadow(.drop(color: .black.opacity(isSelected ? 0.08 : 0), radius: 2, y: 1)),
      in: RoundedRectangle(cornerRadius: 8))
    .onHover { isHovering = $0 }
  }
}
