import AppKit
import ComposableArchitecture
@preconcurrency import EngineCore

// Everything Engine.syncWindow reads from a space, and the web contents it finds for its tabs. Equal keys
// mean the sync would write the same tabs, placements and active tab again.
struct ExtensionWindowKey: Equatable {
  struct TabKey: Equatable {
    let id: Tab.ID
    let placement: Placement
    let contents: ObjectIdentifier?
  }

  struct FolderKey: Equatable {
    let id: Folder.ID
    let placement: Placement
  }

  let tabs: [TabKey]
  let folders: [FolderKey]
  let favoriteRows: [[Tab.ID]]
  let pinnedOrder: [UUID]
  let selectedTabID: Tab.ID?
  let profileID: UUID
  let isIncognito: Bool
  let focused: Bool
  let peeksLinksToOtherSites: Bool

  @MainActor
  init(_ space: Space, tabs: [Tab], focused: Bool) {
    let engine = Engine.shared
    self.tabs = tabs.map { TabKey(id: $0.id, placement: $0.placement, contents: engine.tabs[$0.id].map { ObjectIdentifier($0) }) }
    folders = space.folders.map { FolderKey(id: $0.id, placement: $0.placement) }
    favoriteRows = space.favoriteRows
    pinnedOrder = space.pinnedOrder
    selectedTabID = space.selectedTabID
    profileID = space.profileID
    isIncognito = space.isIncognito
    self.focused = focused
    @Shared(.peeksLinksToOtherSites) var peeks
    peeksLinksToOtherSites = peeks
  }
}

// Each space is its own window to extensions, since its tabs belong to its profile's context. Only the key
// window's selected space is focused, so an extension's current window is the space on screen. A favorite is in
// every space of its profile but a page is in one window, so the selected spaces take their profiles' favorites
// and any other space of the profile takes those left.
extension Shell: @preconcurrency ECWindowDelegate {
  func syncExtensionWindows() {
    var spaces = Set<UUID>()
    var owned: [Tab.ID: Space.ID] = [:]
    let all = store.windows.flatMap(\.spaces.spaces)
    for space in store.windows.map(\.spaces.selected) + all {
      for favorite in space.favorites where owned[favorite.id] == nil {
        owned[favorite.id] = space.id
      }
    }
    for window in store.windows {
      let isKey = controllers[window.id]?.window?.isKeyWindow == true
      for space in window.spaces.spaces {
        spaces.insert(space.id)
        let tabs = space.sidebarOrder.filter { $0.placement != .favorite || owned[$0.id] == space.id }
        let key = ExtensionWindowKey(space, tabs: tabs, focused: isKey && space.id == window.spaces.selectedID)
        guard extensionWindowKeys[space.id] != key else { continue }
        extensionWindowKeys[space.id] = key
        Engine.shared.syncWindow(space, tabs: tabs, focused: key.focused, peeksLinksToOtherSites: key.peeksLinksToOtherSites)
      }
    }
    extensionWindowKeys = extensionWindowKeys.filter { spaces.contains($0.key) }
    for little in store.littleSailfishes {
      spaces.insert(little.id)
    }
    Engine.shared.closeWindows(except: spaces)
  }

  func window(_ window: ECWindow, openTabWith url: URL, active: Bool) -> ECWebContents? {
    guard let id = Engine.shared.windows.first(where: { $0.value === window })?.key,
      let owner = store.windows.first(where: { $0.spaces.spaces[id: id] != nil }),
      let space = owner.spaces.spaces[id: id]
    else { return nil }
    let tab = UUID()
    let contents = Engine.shared.makeContents(tab, space.profileID, space.isIncognito)
    contents.loadURL(url)
    store.send(.windows(.element(id: owner.id, action: .tab(.adopt(tab, url, active: active), in: id))))
    syncExtensionWindows()
    return contents
  }

  func window(_ window: ECWindow, activateTab contents: ECWebContents) {
    Engine.shared.tab(of: contents).map { _ = store.send(.engine(.activateRequested(tab: $0))) }
  }

  func window(_ window: ECWindow, closeTab contents: ECWebContents) {
    Engine.shared.tab(of: contents).map { _ = store.send(.engine(.closeRequested(tab: $0))) }
  }
}
