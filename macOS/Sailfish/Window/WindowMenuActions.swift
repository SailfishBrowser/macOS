import AppKit
import ComposableArchitecture

// The menu bar's Spaces, Tabs and Extensions items for the key window.
extension WindowController: NSMenuItemValidation {
  private var space: Space { store.spaces.selected }

  // ⌘. stops a loading page; otherwise it moves the keyboard into the sidebar.
  @objc func stopLoading(_ sender: Any?) {
    store.send(space.selectedTab?.isLoading == true ? .tab(.stop, in: space.id) : .sidebar(.focusList))
  }

  // The command bar's Toggle Sidebar, titled so whichever way the sidebar is; the menu item's title flips. Its
  // own selector, as SwiftUI's hosting view answers toggleSidebar: before the window controller.
  @objc func toggleSidebarCommand(_ sender: Any?) {
    toggleSidebarDocking(sender)
  }

  // Lock (or anchor) the sidebar: a hidden sidebar docks again.
  @objc func lockSidebar(_ sender: Any?) {
    guard store.sidebar.isFloating else { return }
    store.send(.sidebar(.toggle))
  }

  @objc func selectSpace(_ sender: NSMenuItem) {
    store.send(.spaces(.select(store.spaces.spaces[sender.tag].id)))
  }

  @objc func manageSpaces(_ sender: Any?) {
    store.send(.showLibrary(.spaces))
  }

  // Pin Tab, or Pin Tabs for a multi-selection.
  @objc func togglePin(_ sender: Any?) {
    let tabs = space.hasSelection ? space.selectedTabs.map(\.id) : space.selectedTabID.map { [$0] } ?? []
    for tab in tabs {
      store.send(.tab(.togglePin(tab), in: space.id))
    }
  }

  @objc func duplicateTab(_ sender: Any?) {
    guard let tab = space.selectedTabID else { return }
    store.send(.tab(.duplicate(tab), in: space.id), animation: Motion.layout)
  }

  // Rename Current Tab: the selected tab's row, opened into view as Reveal does, turns into a name field.
  @objc func renameCurrentTab(_ sender: Any?) {
    revealTabInSidebar(sender)
    store.send(.sidebar(.renameTab))
  }

  // ⌘1-⌘8 go to the sidebar's nth item; ⌘9 (tag 8) to the last.
  @objc func selectSidebarItem(_ sender: NSMenuItem) {
    store.send(.tab(.selectSidebarItem(sender.tag < 8 ? sender.tag : nil), in: space.id))
  }

  @objc func cycleTabForward(_ sender: Any?) {
    cycleRecentTab(older: true)
  }

  @objc func cycleTabBackward(_ sender: Any?) {
    cycleRecentTab(older: false)
  }

  // The switcher's card for the tab showing now gets its page as it looks at this moment.
  private func cycleRecentTab(older: Bool) {
    if store.recentCycle == nil, let tab = space.selectedTabID {
      Engine.shared.captureThumbnail(tab)
    }
    store.send(.cycleRecentTab(older: older))
    // A cycle that starts with ⌃ already released, as after leaving a WebKit page's full screen, ends on its tab.
    if !NSEvent.modifierFlags.contains(.control) {
      store.send(.endRecentCycle)
    }
  }

  // ⌥⌘V: the clipboard's link, or a search for its text, in a new tab.
  @objc func pasteAsNewTab(_ sender: Any?) {
    guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else { return }
    store.send(.tab(.open(.pasted(text)), in: space.id), animation: Motion.layout)
  }

  @objc func muteAllTabs(_ sender: Any?) {
    for space in store.spaces.spaces {
      store.send(.tab(.muteAll(true), in: space.id))
    }
  }

  @objc func unmuteAllTabs(_ sender: Any?) {
    for space in store.spaces.spaces {
      store.send(.tab(.muteAll(false), in: space.id))
    }
  }

  // Reset Tab to Original URL: a pinned tab that moved on goes back to its pinned URL.
  @objc func resetTabToPinnedURL(_ sender: Any?) {
    guard let tab = space.selectedTabID else { return }
    store.send(.tab(.resetToPinnedURL(tab), in: space.id))
  }

  @objc func togglePinnedSection(_ sender: Any?) {
    store.send(.tab(.togglePinnedSection, in: space.id), animation: Motion.row)
  }

  // Open Page in WebKit or Chromium: the shown page again in the other engine.
  @objc func openPageInOtherEngine(_ sender: Any?) {
    guard let tab = space.selectedTabID, let engine = Engine.shared.otherEngine(tab) else { return }
    store.send(.tab(.switchEngine(tab, engine), in: space.id))
  }

  @objc func reloadBypassingCache(_ sender: Any?) {
    guard let tab = space.selectedTabID else { return }
    Task { await Engine.shared.reload(tab, bypassingCache: true) }
  }

  @objc func newSplit(_ sender: Any?) {
    store.send(.newSplit)
  }

  // Closes the selected pane's tab; the pane beside it takes the selection.
  @objc func closeSplitPane(_ sender: Any?) {
    guard let tab = space.selectedTabID else { return }
    store.send(.tab(.close(tab), in: space.id))
  }

  @objc func separatePane(_ sender: Any?) {
    guard let tab = space.selectedTabID else { return }
    store.send(.tab(.separate(tab), in: space.id))
  }

  @objc func expandCurrentSplit(_ sender: Any?) {
    store.send(.toggleExpandedPane)
  }

  // Opens the folders and the pinned section the selected tab sits in, then scrolls it into view.
  @objc func revealTabInSidebar(_ sender: Any?) {
    guard let tab = space.selectedTab else { return }
    var placement = tab.placement
    while case let .folder(id) = placement, let folder = space.folders[id: id] {
      if !folder.isOpen { store.send(.tab(.toggleFolder(id), in: space.id), animation: Motion.row) }
      placement = folder.placement
    }
    if tab.placement.isPinnedSection, space.isPinnedCollapsed {
      store.send(.tab(.togglePinnedSection, in: space.id), animation: Motion.row)
    }
    store.send(.sidebar(.reveal))
  }

  @objc func expandAllFolders(_ sender: Any?) {
    store.send(.tab(.setAllFolders(isOpen: true), in: space.id), animation: Motion.row)
  }

  @objc func collapseAllFolders(_ sender: Any?) {
    store.send(.tab(.setAllFolders(isOpen: false), in: space.id), animation: Motion.row)
  }

  // Closes the folder the selected tab is in.
  @objc func closeThisFolder(_ sender: Any?) {
    guard let folder = openFolderOfSelectedTab else { return }
    store.send(.tab(.toggleFolder(folder), in: space.id), animation: Motion.row)
  }

  private var openFolderOfSelectedTab: Folder.ID? {
    guard case let .folder(id)? = space.selectedTab?.placement, space.folders[id: id]?.isOpen == true else { return nil }
    return id
  }

  // Asks before emptying the archive, then confirms with a toast.
  @objc func clearArchive(_ sender: Any?) {
    guard let window else { return }
    presentModal(over: window) { [store] dismiss in
      ClearArchiveDialog(clear: { store.send(.clearArchive) }, dismiss: dismiss)
    }
  }

  // Reset all tabs in this Space: pinned tabs go back to their pinned URLs.
  @objc func resetSpaceTabs(_ sender: Any?) {
    for tab in space.tabs where tab.hasLeftPinnedURL {
      store.send(.tab(.resetToPinnedURL(tab.id), in: space.id))
    }
  }

  // Asks for the name first, then adds the folder at the end of the pinned section; with tabs selected it
  // is New Folder from Selection.
  @objc func newFolder(_ sender: Any?) {
    guard let window else { return }
    let current = space
    let tabs = current.hasSelection ? current.selectedTabs.map(\.id) : []
    let container = tabs.isEmpty ? Placement.pinned : current.selectionContainer
    presentModal(over: window) { [store] dismiss in
      NewFolderDialog(
        create: { store.send(.tab(.newFolder($0, in: container, with: tabs), in: current.id), animation: Motion.row) },
        dismiss: dismiss)
    }
  }

  // The command bar's "New Folder with N items…", which names the folder through the dialog.
  @objc func newFolderFromSelection(_ sender: Any?) {
    newFolder(sender)
  }

  // The command bar's folder rows: the folder opens in the sidebar, or the shown tab is pinned into it.
  @objc func openFolder(_ sender: NSMenuItem) {
    guard space.folders.indices.contains(sender.tag) else { return }
    store.send(.tab(.openFolder(space.folders[sender.tag].id), in: space.id), animation: Motion.row)
    store.send(.sidebar(.reveal))
  }

  @objc func pinTabToFolder(_ sender: NSMenuItem) {
    guard space.folders.indices.contains(sender.tag), let tab = space.selectedTabID else { return }
    store.send(.tab(.move(tab, .folder(space.folders[sender.tag].id), before: nil), in: space.id), animation: Motion.row)
  }

  @objc func newSpace(_ sender: Any?) {
    store.send(.sidebar(.editSpace(creating: true)))
  }

  @objc func renameSpace(_ sender: Any?) {
    guard let window else { return }
    let space = space
    presentModal(over: window) { [store] dismiss in
      RenameSpaceDialog(
        space: space.name, save: { store.send(.spaces(.update(space.id, name: $0, icon: space.icon, theme: space.theme))) },
        dismiss: dismiss)
    }
  }

  @objc func changeProfile(_ sender: Any?) {
    guard let window else { return }
    let space = space
    let profiles = store.spaces.profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    presentModal(over: window) { [store] dismiss in
      ChangeProfileDialog(
        space: space.name, profiles: profiles, current: space.profileID,
        change: { store.send(.spaces(.setProfile(space.id, $0))) }, dismiss: dismiss)
    }
  }

  @objc func editTheme(_ sender: Any?) {
    store.send(.sidebar(.editSpace(creating: false)))
  }

  @objc func toggleSpaceHeader(_ sender: Any?) {
    store.send(.tab(.toggleHeader, in: space.id))
  }

  @objc func clearToday(_ sender: Any?) {
    store.send(.tab(.clearToday, in: space.id))
  }

  @objc func clearUnselectedTabs(_ sender: Any?) {
    store.send(.tab(.clearUnselected, in: space.id))
  }

  // The command bar's Run Extension: its popup opens on the URL pill, the page's own control.
  @objc func runExtension(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    store.send(.runExtension(id))
  }

  @objc func addExtension(_ sender: Any?) {
    store.send(.tab(.open(URL(string: "https://chromewebstore.google.com")!), in: space.id))
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(selectSpace(_:)):
      let spaces = store.isIncognito ? [] : store.spaces.spaces.elements
      item.isHidden = item.tag >= spaces.count
      item.title = item.isHidden ? "" : spaces[item.tag].name
      item.state = item.isHidden || spaces[item.tag].id != space.id ? .off : .on
      return !item.isHidden
    case #selector(togglePin(_:)):
      if space.hasSelection {
        let placements = Set(space.selectedTabs.map(\.placement))
        item.title = placements == [.pinned] ? "Unpin Tabs" : "Pin Tabs"
        return placements.allSatisfy { $0 == .pinned || $0 == .unpinned }
      }
      let placement = space.selectedTab?.placement
      item.title = placement == .pinned ? "Unpin Tab" : "Pin Tab"
      return placement == .pinned || placement == .unpinned
    case #selector(toggleSpaceHeader(_:)):
      item.title = space.isHeaderHidden ? "Show Space Header" : "Hide Space Header"
      return !store.isIncognito
    case #selector(togglePinnedSection(_:)):
      item.title = space.isPinnedCollapsed ? "Expand Pinned Tabs" : "Collapse Pinned Tabs"
      return !store.isIncognito && !space.rows(in: .pinned).isEmpty
    // The Window menu says Close Library while it is open, and Hide Downloads or Hide Media on that pane.
    case #selector(toggleLibrary(_:)):
      item.title = store.isLibraryOpen ? "Close Library" : "Open Library…"
      return true
    case #selector(openLibrary(_:)) where [0, 4].contains(item.tag):
      let name = item.tag == 0 ? "Downloads" : "Media"
      item.title = store.isLibraryOpen && store.library?.pane.rawValue == item.tag ? "Hide \(name)" : "View \(name)…"
      return true
    case #selector(toggleSidebarDocking(_:)):
      item.title = store.sidebar.isFloating ? "Show Sidebar" : "Hide Sidebar"
      return true
    case #selector(lockSidebar(_:)):
      return store.sidebar.isFloating
    case #selector(renameSpace(_:)), #selector(changeProfile(_:)), #selector(importFromArc(_:)):
      return !store.isIncognito
    case #selector(clearToday(_:)):
      return !space.clearableTabs.isEmpty
    case #selector(clearUnselectedTabs(_:)):
      return !space.unselectedTabs.isEmpty
    case #selector(closeSplitPane(_:)), #selector(separatePane(_:)):
      return space.split(of: space.selectedTabID) != nil
    case #selector(expandCurrentSplit(_:)):
      item.state = store.expandedPane == nil ? .off : .on
      return space.split(of: space.selectedTabID) != nil
    case #selector(newSplit(_:)):
      return (space.split(of: space.selectedTabID)?.tabIDs.count ?? 1) < Space.maxPanes
    case #selector(revealTabInSidebar(_:)), #selector(duplicateTab(_:)), #selector(renameCurrentTab(_:)):
      return space.selectedTabID != nil
    case #selector(selectSidebarItem(_:)):
      return !space.sidebarItems.isEmpty
    case #selector(resetTabToPinnedURL(_:)):
      return space.selectedTab?.hasLeftPinnedURL == true
    case #selector(pasteAsNewTab(_:)):
      return NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    case #selector(resetSpaceTabs(_:)):
      return space.tabs.contains(where: \.hasLeftPinnedURL)
    case #selector(newFolder(_:)):
      item.title = space.hasSelection ? "New Folder from Selection…" : "New Folder…"
      return true
    case #selector(newFolderFromSelection(_:)):
      item.title = "New Folder with \(space.selectedTabs.count) items…"
      return space.hasSelection
    case #selector(openFolder(_:)):
      return space.folders.indices.contains(item.tag)
    case #selector(pinTabToFolder(_:)):
      guard space.folders.indices.contains(item.tag), let tab = space.selectedTab else { return false }
      return tab.placement != .folder(space.folders[item.tag].id)
    case #selector(expandAllFolders(_:)):
      return space.folders.contains { !$0.isOpen }
    case #selector(collapseAllFolders(_:)):
      return space.folders.contains(where: \.isOpen)
    case #selector(closeThisFolder(_:)):
      return openFolderOfSelectedTab != nil
    case #selector(clearArchive(_:)):
      @Shared(.archive) var archive
      return !archive.isEmpty
    case #selector(copyURLAsQuote(_:)):
      return space.selectedTabID.flatMap { Engine.shared.selections[$0] } != nil
    case #selector(showJavaScriptConsole(_:)), #selector(inspectElements(_:)):
      return space.selectedTabID.flatMap { Engine.shared.page($0) }?.hasDeveloperTools == true
    case #selector(viewSource(_:)):
      return space.selectedTabID.flatMap { Engine.shared.page($0) } != nil
    case #selector(stopLoading(_:)):
      return true
    // Offered only on a page with an article, as Safari does.
    case #selector(toggleReader(_:)):
      guard let tab = space.selectedTabID else { return false }
      let isShown = Engine.shared.readers[tab] != nil
      item.title = isShown ? "Hide Reader View" : "Show Reader View"
      return isShown || Engine.shared.readerable.contains(tab)
    case #selector(openPageInOtherEngine(_:)):
      let engine = space.selectedTabID.flatMap { Engine.shared.otherEngine($0) }
      item.title = "Open Page in \((engine ?? .webkit).name)"
      return engine != nil
    case #selector(useSelectionForFind(_:)):
      return space.selectedTabID.flatMap { Engine.shared.selections[$0] } != nil
    // Enabled for any loaded page, as in Chrome: the page keeps a selection the engine never reported, such as
    // the match the find bar left selected.
    case #selector(jumpToSelection(_:)):
      return space.selectedTabID.flatMap { Engine.shared.page($0) } != nil
    // Disabled, the key goes on to the field, which moves its caret. A page's own fields keep it in the engine.
    case #selector(goBackWithArrow(_:)), #selector(goForwardWithArrow(_:)):
      return !(window?.firstResponder is NSText)
    default:
      return true
    }
  }
}

extension URL {
  // ⌥⌘V's page: a link with a scheme, or a bare address like example.com, loads; a host with a port or an IP
  // address loads over http, as a local server would serve it; any other text is searched.
  static func pasted(_ text: String) -> URL {
    let local = #/(localhost|\d{1,3}(\.\d{1,3}){3}|[\w-]+(\.[\w-]+)*:\d+)(:\d+)?(/.*)?/#
    if text.wholeMatch(of: local) != nil, let url = URL(string: "http://" + text) { return url }
    if let url = URL(string: text), url.scheme != nil, url.host() != nil || url.isFileURL { return url }
    if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host() != nil { return url }
    return CommandBarFeature.searchURL(text)
  }
}
