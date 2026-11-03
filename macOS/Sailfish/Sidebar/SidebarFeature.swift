import ComposableArchitecture
import Foundation
import SwiftUI

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
    // How many of the sidebar's own popovers are open. While one is, a floating sidebar stays out, so the
    // pointer can move into the popover without the card sliding away under it.
    var openPopovers = 0
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
    // A sidebar popover opened or closed; while any is open the floating card stays out.
    case popover(Bool)
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
        // A popover hanging off the sidebar keeps a floating card out while the pointer visits it.
        if !isPeeking, state.openPopovers > 0 { return .none }
        state.isPeeking = isPeeking && state.isFloating
      case let .popover(isOpen):
        state.openPopovers = max(0, state.openPopovers + (isOpen ? 1 : -1))
        if isOpen, state.isFloating { state.isPeeking = true }
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

// Where a sidebar popover reports that it opened or closed. While one is open a floating sidebar stays out, so
// the pointer can travel into the popover without the card sliding away underneath it.
private struct SidebarPopoverReporterKey: EnvironmentKey {
  static let defaultValue: @MainActor @Sendable (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
  var sidebarPopoverReporter: @MainActor @Sendable (Bool) -> Void {
    get { self[SidebarPopoverReporterKey.self] }
    set { self[SidebarPopoverReporterKey.self] = newValue }
  }
}

extension View {
  // A popover hanging off the sidebar, reported while it shows. Away from the sidebar, where no reporter is
  // set, it is an ordinary popover.
  func sidebarPopover<PopoverContent: View>(
    isPresented: Binding<Bool>, arrowEdge: Edge = .bottom,
    @ViewBuilder content: @escaping () -> PopoverContent
  ) -> some View {
    popover(isPresented: isPresented, arrowEdge: arrowEdge) {
      content().sidebarPopoverReported()
    }
  }

  func sidebarPopover<Item: Identifiable, PopoverContent: View>(
    item: Binding<Item?>, arrowEdge: Edge = .bottom,
    @ViewBuilder content: @escaping (Item) -> PopoverContent
  ) -> some View {
    popover(item: item, arrowEdge: arrowEdge) {
      content($0).sidebarPopoverReported()
    }
  }
}

private extension View {
  func sidebarPopoverReported() -> some View { modifier(SidebarPopoverReport()) }
}

private struct SidebarPopoverReport: ViewModifier {
  @Environment(\.sidebarPopoverReporter) private var report

  func body(content: Content) -> some View {
    content
      .onAppear { report(true) }
      .onDisappear { report(false) }
  }
}
