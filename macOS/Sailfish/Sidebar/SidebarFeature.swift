import ComposableArchitecture
import Foundation

extension SharedKey where Self == AppStorageKey<Double>.Default {
  // The docked sidebar's width, which the user drags its trailing edge to set; one width for every window.
  static var sidebarWidth: Self { Self[.appStorage("sidebarWidth"), default: 219] }
}

@Reducer
struct SidebarFeature {
  @ObservableState
  struct State: Codable, Equatable {
    var isFloating = false
    var showsFavoritesHint = true
    var isPeeking = false
    // A row is being dragged, which may take the pointer out of a floating sidebar.
    var isDraggingRow = false
    // The pointer left the floating sidebar during a drag, so it hides once the drag ends.
    var hidesAfterDrag = false
    // The space editor the command bar asked for: true to create a space, false to edit the selected one.
    var spaceEditorRequest: Bool?
    // How far a two-finger swipe has moved the spaces' strip; positive moves toward the previous space.
    var swipe: CGFloat?
    @Shared(.sidebarWidth) var width

    static let widths = 180.0...400
    // Counts Reveal Tab in Sidebar requests; each scrolls the selected tab into view.
    var reveals = 0
    // Counts ⌘. requests to move the keyboard focus into the sidebar's list.
    var focusRequests = 0
    // Rename Current Tab turns the selected tab's title into a field; the view clears the request.
    var tabRenameRequest = false

    // How far past the last space a swipe goes before it lifts into Create a Space.
    static let createDistance: CGFloat = 170

    var isVisible: Bool { !isFloating || isPeeking }
    // The floating card sits 3 pt narrower, inset in the window.
    var visibleWidth: Double { isFloating ? width - 3 : width }

    enum CodingKeys: String, CodingKey {
      case _isFloating = "isFloating", _showsFavoritesHint = "showsFavoritesHint"
    }
  }

  enum Action {
    case dismissFavoritesHint
    case dragRow(Bool)
    case editSpace(creating: Bool?)
    // ⌘.: a hidden sidebar slides out and its list takes the arrow keys.
    case focusList
    case peek(Bool)
    case resize(Double)
    // Reveal Tab in Sidebar: a hidden sidebar slides out, and the list scrolls to the selected tab.
    case reveal
    // Rename Current Tab: a hidden sidebar slides out with the selected tab's title ready to edit.
    case renameTab
    case tabRenameHandled
    case toggle
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .dismissFavoritesHint:
        state.showsFavoritesHint = false
      case let .dragRow(isDragging):
        state.isDraggingRow = isDragging
        if !isDragging, state.hidesAfterDrag {
          state.isPeeking = false
        }
        state.hidesAfterDrag = false
      case .focusList:
        state.isPeeking = state.isFloating
        state.focusRequests += 1
      case let .editSpace(creating):
        state.spaceEditorRequest = creating
        // A hidden sidebar slides out to show the editor.
        state.isPeeking = state.isPeeking || creating != nil && state.isFloating
      case let .peek(isPeeking):
        // Leaving during a drag would take the dragged row's sidebar away mid-drag.
        guard !state.isDraggingRow else {
          state.hidesAfterDrag = !isPeeking
          return .none
        }
        state.isPeeking = isPeeking && state.isFloating
      case let .resize(width):
        state.$width.withLock { $0 = min(max(width, State.widths.lowerBound), State.widths.upperBound) }
      case .reveal:
        state.isPeeking = state.isFloating
        state.reveals += 1
      case .renameTab:
        state.isPeeking = state.isFloating
        state.tabRenameRequest = true
      case .tabRenameHandled:
        state.tabRenameRequest = false
      case .toggle:
        state.isFloating.toggle()
        state.isPeeking = false
      }
      return .none
    }
  }
}
