import ComposableArchitecture
import Foundation

@Reducer
struct FindFeature {
  @ObservableState
  struct State: Equatable {
    let tab: Tab.ID
    var query = ""
    var matches = 0
    var activeMatch = 0
    // Whether the page has answered the current query.
    var hasResult = false

    // A red NOT FOUND in place of the count.
    var isNotFound: Bool { !query.isEmpty && hasResult && matches == 0 }
  }

  enum Action {
    case close
    case found(matches: Int, activeMatch: Int)
    case next
    case previous
    case queryChanged(String)
  }

  @Dependency(\.dismiss) var dismiss
  @Dependency(\.webEngine) var engine

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .close:
        return .run { [tab = state.tab, now = ContinuousClock.now] _ in
          await engine.stopFinding(tab, now)
          await dismiss()
        }

      case let .found(matches, activeMatch):
        state.matches = matches
        state.activeMatch = activeMatch
        state.hasResult = true
        return .none

      case .next:
        return find(state, forward: true)

      case .previous:
        return find(state, forward: false)

      // Each keystroke's search runs in its own effect, and effects reach the engine in no fixed order, so each
      // carries the time it was asked for and the engine drops one older than the last it ran. Cancelling the
      // older effects instead would let one that starts late cancel the newest search before it reached the
      // engine.
      case let .queryChanged(query):
        state.query = query
        state.hasResult = false
        guard !query.isEmpty else {
          return .run { [tab = state.tab, now = ContinuousClock.now] _ in await engine.stopFinding(tab, now) }
        }
        // As typed: the same text again keeps the active match, so slow typing never steps to the second one.
        return .run { [tab = state.tab, now = ContinuousClock.now] _ in await engine.findAsTyped(tab, query, now) }
      }
    }
  }

  private func find(_ state: State, forward: Bool) -> Effect<Action> {
    guard !state.query.isEmpty else { return .none }
    return .run { [tab = state.tab, query = state.query, now = ContinuousClock.now] _ in
      await engine.find(tab, query, forward, now)
    }
  }
}
