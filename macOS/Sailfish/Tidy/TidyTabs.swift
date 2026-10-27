import ComposableArchitecture
import Foundation

extension TabsFeature {
  // Tidy: the Today tabs sorted into named groups, on the Mac, while the broom sweeps once.
  @CasePathable
  enum Tidy {
    case start
    case swept
  }

  // Tidy shows once Today has six tabs to sort.
  static let tidyMinimum = 6
  static let sweep = Duration.milliseconds(600)

  func tidy(_ state: inout State, _ action: Action) -> Effect<Action> {
    switch action {
    case .tidy(.start):
      guard !state.isTidying else { return .none }
      state.isTidying = true
      let layout = TabLayout(state)
      for group in sortIntoGroups(state.tidyCandidates.map(TidyTab.init)) {
        let made = TabGroup(id: uuid(), name: group.name, color: state.nextGroupColor)
        state.groups.append(made)
        for id in group.tabIDs {
          state.ownTabs[id: id]?.groupID = made.id
        }
      }
      let found = TabLayout(state) != layout
      return .merge(
        .send(.delegate(found ? .moved(layout) : .tidyMessage("No tab groups found"))),
        .run { send in
          try await clock.sleep(for: Self.sweep)
          await send(.tidy(.swept))
        })

    case .tidy(.swept):
      state.isTidying = false
      return .none

    default:
      return .none
    }
  }
}

extension TabsFeature.State {
  // The Today tabs Tidy sorts: those in no group, and not in a split, whose panes stay together.
  var tidyCandidates: [Tab] {
    tabs(in: .unpinned).filter { $0.groupID == nil && split(of: $0.id) == nil }
  }
}

extension TidyTab {
  init(_ tab: Tab) {
    self.init(id: tab.id, title: tab.displayTitle, host: tab.url.host() ?? "")
  }
}
