import ComposableArchitecture
import SwiftUI

// A named, colored group of Today tabs, shown as a header with its tabs indented under it, as in Dia.
struct TabGroup: Codable, Equatable, Identifiable {
  let id: UUID
  var name: String
  var color: Color
  var isOpen = true

  // Chromium's tab group colors, in its order.
  enum Color: String, Codable, CaseIterable {
    case grey, blue, red, yellow, green, pink, purple, cyan, orange

    var name: String { rawValue.capitalized }

    var swatch: SwiftUI.Color {
      SwiftUI.Color(hex: hex)
    }

    var hex: UInt32 {
      switch self {
      case .grey: 0x9AA0A6
      case .blue: 0x1A73E8
      case .red: 0xD93025
      case .yellow: 0xF9AB00
      case .green: 0x1E8E3E
      case .pink: 0xD01884
      case .purple: 0x9334E6
      case .cyan: 0x007B83
      case .orange: 0xFA903E
      }
    }
  }
}

extension TabsFeature.State {
  // The group's tabs in sidebar order.
  func members(of group: TabGroup.ID) -> [Tab] {
    tabs(in: .unpinned).filter { $0.groupID == group }
  }

  // As Chromium picks: the color fewest groups have, first in order on a tie.
  var nextGroupColor: TabGroup.Color {
    TabGroup.Color.allCases.min { color, other in
      groups.count { $0.color == color } < groups.count { $0.color == other }
    }!
  }

  // Whether a Today tab's row shows: a closed group folds its rows away, all but the shown ones.
  func isFoldedInGroup(_ tab: Tab) -> Bool {
    guard let group = tab.groupID.flatMap({ groups[id: $0] }) else { return false }
    return !group.isOpen && !shownTabIDs.contains(tab.id)
  }

  // Keeps groups whole: only Today tabs of a group the space has belong to one, a group without tabs goes, and a
  // group's tabs sit together where its first one is.
  mutating func tidyGroups() {
    guard !groups.isEmpty || ownTabs.contains(where: { $0.groupID != nil }) else { return }
    for tab in ownTabs where tab.groupID != nil && (tab.placement != .unpinned || groups[id: tab.groupID!] == nil) {
      ownTabs[id: tab.id]?.groupID = nil
    }
    let used = Set(ownTabs.compactMap(\.groupID))
    if groups.contains(where: { !used.contains($0.id) }) {
      groups.removeAll { !used.contains($0.id) }
    }
    var order: [Tab] = []
    var placed: Set<TabGroup.ID> = []
    for tab in ownTabs {
      guard let group = tab.groupID else {
        order.append(tab)
        continue
      }
      if placed.insert(group).inserted {
        order += ownTabs.filter { $0.groupID == group }
      }
    }
    if order.map(\.id) != ownTabs.ids.elements {
      ownTabs = IdentifiedArray(uniqueElements: order)
    }
  }
}
