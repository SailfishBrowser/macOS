import AppKit
import Dependencies

typealias Command = CommandBarFeature.Command

// The app commands the command bar offers, and running them.
struct AppCommandsClient: Sendable {
  // The commands the key window can run now, titled as its menu items are (Pin Tab or Unpin Tab).
  var available: @Sendable () -> [Command]
  var perform: @Sendable (Command) async -> Void
}

extension AppCommandsClient: DependencyKey {
  static let liveValue = Self(
    available: { MainActor.assumeIsolated { AppCommands.available() } },
    perform: { command in await MainActor.run { AppCommands.perform(command) } }
  )
  static let testValue = Self(available: { [] }, perform: { _ in })
}

extension DependencyValues {
  var appCommands: AppCommandsClient {
    get { self[AppCommandsClient.self] }
    set { self[AppCommandsClient.self] = newValue }
  }
}

@MainActor
enum AppCommands {
  static let all: [Command] = [
    Command(title: "Settings", symbol: "gearshape", action: "showSettings:", keywords: "preferences"),
    Command(title: "Open Library…", symbol: "archivebox", shortcut: "⇧⌘L", action: "toggleLibrary:"),
    Command(title: "View Downloads…", symbol: "arrow.down.circle", shortcut: "⇧⌘J", action: "openLibrary:"),
    Command(title: "View Archive…", symbol: "archivebox", action: "openLibrary:", tag: 3, keywords: "archived tabs"),
    Command(title: "Manage Spaces…", symbol: "square.on.square", action: "manageSpaces:"),
    Command(title: "New Space…", symbol: "plus.rectangle.portrait", action: "newSpace:"),
    Command(title: "Edit Theme…", symbol: "paintbrush.pointed.fill", action: "editTheme:", keywords: "color space"),
    Command(title: "Edit Keyboard Shortcuts", symbol: "gearshape", action: "showSettings:", tag: SettingsPane.shortcuts.rawValue, keywords: "keybinds"),
    Command(title: "Open Link Preferences", symbol: "gearshape", action: "showSettings:", tag: SettingsPane.links.rawValue, keywords: "little sailfish"),
    Command(title: "Open Profile Preferences", symbol: "gearshape", action: "showSettings:", tag: SettingsPane.profiles.rawValue),
    Command(title: "Toggle Sidebar", symbol: "sidebar.left", shortcut: "⌘S", action: "toggleSidebarCommand:", keywords: "hide show lock anchor"),
    // Its lock or anchor action, offered while the sidebar is hidden.
    Command(title: "Show Sidebar", symbol: "sidebar.left", action: "lockSidebar:", keywords: "lock anchor"),
    Command(title: "Archive Tab", symbol: "archivebox", shortcut: "⌘W", action: "closeTab:", keywords: "close"),
    Command(title: "Copy URL", symbol: "doc.on.doc", shortcut: "⇧⌘C", action: "copyURL:", keywords: "link"),
    Command(title: "Pin Tab", symbol: "pin", shortcut: "⌘D", action: "togglePin:"),
    Command(title: "Paste URL as New Tab", symbol: "doc.on.clipboard", shortcut: "⌥⌘V", action: "pasteAsNewTab:", keywords: "clipboard"),
    Command(title: "Mute all tabs", symbol: "speaker.slash", action: "muteAllTabs:", keywords: "sound audio"),
    Command(title: "Unmute all tabs", symbol: "speaker.wave.2", action: "unmuteAllTabs:", keywords: "sound audio"),
    Command(title: "Add Split View", symbol: "rectangle.split.2x1", shortcut: "⌃⇧=", action: "newSplit:", keywords: "new"),
    Command(title: "Show Reader View", symbol: "doc.plaintext", shortcut: "⌥⌘R", action: "toggleReader:", keywords: "reader mode article"),
    Command(title: "View History", symbol: "book", shortcut: "⌘Y", action: "viewHistory:"),
    Command(title: "Manage Extensions…", symbol: "puzzlepiece.extension", action: "showExtensions:"),
    Command(title: "Manage Passwords", symbol: "key", action: "managePasswords:", keywords: "password manager"),
    Command(title: "New Incognito Window", symbol: "macwindow.on.rectangle", shortcut: "⇧⌘N", action: "newIncognitoWindow:"),
    Command(title: "New Little Sailfish Window", symbol: "macwindow", shortcut: "⌥⌘N", action: "newLittleSailfish:"),
    Command(title: "Show Little Sailfish Windows", symbol: "macwindow.on.rectangle", action: "showAllLittleSailfishes:", keywords: "all"),
    Command(title: "Close Little Sailfish Windows", symbol: "xmark.circle", action: "closeAllLittleSailfishes:", keywords: "all"),
    Command(title: "Copy URL as Markdown", symbol: "doc.on.doc", shortcut: "⌥⇧⌘C", action: "copyURLAsMarkdown:", isMinor: true),
    Command(title: "Rename Current Tab", symbol: "pencil", action: "renameCurrentTab:", isMinor: true),
    Command(title: "Duplicate Current Tab", symbol: "plus.square.on.square", action: "duplicateTab:", isMinor: true),
    Command(title: "Restore Last Closed Tab", symbol: "arrow.uturn.backward", shortcut: "⇧⌘T", action: "reopenClosedTab:", isMinor: true),
    Command(title: "Clear Today", symbol: "archivebox", shortcut: "⇧⌘K", action: "clearToday:", isMinor: true),
    Command(title: "Clear Unselected Tabs", symbol: "archivebox", action: "clearUnselectedTabs:", keywords: "today unpinned", isMinor: true),
    Command(title: "New Folder…", symbol: "plus.circle", action: "newFolder:", isMinor: true),
    // Titled with the selection's count by the window, as the menu item is.
    Command(title: "New Folder with Selected Items", symbol: "plus.circle", action: "newFolderFromSelection:", keywords: "selection"),
    Command(title: "Expand All Folders", symbol: "folder", action: "expandAllFolders:", isMinor: true),
    Command(title: "Collapse All Folders", symbol: "folder", action: "collapseAllFolders:", isMinor: true),
    Command(title: "Close This Folder", symbol: "folder", action: "closeThisFolder:", isMinor: true),
    Command(title: "Clear Archive", symbol: "archivebox", action: "clearArchive:", isMinor: true),
    Command(title: "Add Extension…", symbol: "puzzlepiece.extension", action: "addExtension:", isMinor: true),
    Command(title: "Import from Another Browser…", symbol: "square.and.arrow.down", action: "importBrowserData:", isMinor: true),
    Command(title: "Import from Arc…", symbol: "square.and.arrow.down", action: "importFromArc:", keywords: "spaces shortcuts", isMinor: true),
    Command(title: "New Window", symbol: "macwindow", shortcut: "⌘N", action: "newWindow:", isMinor: true),
    Command(title: "Close Window", symbol: "xmark.circle", shortcut: "⇧⌘W", action: "performClose:", isMinor: true),
    Command(title: "Next Tab", symbol: "arrow.right", shortcut: "⌥⌘↓", action: "nextTab:", isMinor: true),
    Command(title: "Previous Tab", symbol: "arrow.left", shortcut: "⌥⌘↑", action: "previousTab:", isMinor: true),
    Command(title: "Next Space", symbol: "arrow.right.to.line", shortcut: "⌥⌘→", action: "nextSpace:", isMinor: true),
    Command(title: "Previous Space", symbol: "arrow.left.to.line", shortcut: "⌥⌘←", action: "previousSpace:", isMinor: true),
    Command(title: "Zoom In", symbol: "plus.magnifyingglass", shortcut: "⌘+", action: "zoomIn:", isMinor: true),
    Command(title: "Zoom Out", symbol: "minus.magnifyingglass", shortcut: "⌘-", action: "zoomOut:", isMinor: true),
    Command(title: "Zoom to Actual Size", symbol: "1.magnifyingglass", shortcut: "⌘0", action: "resetZoom:", isMinor: true),
  ]

  static func available() -> [Command] {
    (all + folderCommands() + extensions()).compactMap { command in
      let item = item(for: command)
      guard let target = NSApp.target(forAction: item.action!, to: item.target, from: item),
        (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
      else { return nil }
      var command = command
      command.title = item.title
      // The keys as the menu bar has them now, custom shortcuts included.
      // Only the item with the command's own action and tag gives its keys (Settings… does not give its ⌘, to
      // Edit Keyboard Shortcuts).
      if let source = menuItem(for: command), source.tag == command.tag, case let keys = ShortcutsPane.keys(source),
        keys != "---"
      {
        command.shortcut = keys
      }
      return command
    }
  }

  // An extension typed by name in the command bar runs: one command per extension with an action for the
  // key window's page.
  private static func extensions() -> [Command] {
    guard let store = (NSApp.keyWindow?.windowController as? WindowController)?.store else { return [] }
    let space = store.spaces.selected
    guard let tab = space.selectedTabID else { return [] }
    return Engine.shared.extensionActions(tab, in: space).map {
      Command(
        title: $0.extension.name, symbol: "puzzlepiece.extension", action: "runExtension:", argument: $0.id,
        keywords: "extension")
    }
  }

  // "Open [Folder]" and "Pin Tab to [Folder]": one pair per folder of the key window's space, by index.
  private static func folderCommands() -> [Command] {
    guard let space = (NSApp.keyWindow?.windowController as? WindowController)?.store.spaces.selected else { return [] }
    return space.folders.enumerated().flatMap { index, folder in
      [
        Command(title: folder.name, symbol: "folder", action: "openFolder:", tag: index, keywords: "open folder"),
        Command(title: "Pin Tab to “\(folder.name)”", symbol: "pin", action: "pinTabToFolder:", tag: index, keywords: "move folder", isMinor: true),
      ]
    }
  }

  static func perform(_ command: Command) {
    let item = item(for: command)
    NSApp.sendAction(item.action!, to: item.target, from: item)
  }

  // An item like the menu bar's, aimed at the menu item's target for the app's own actions.
  private static func item(for command: Command) -> NSMenuItem {
    let item = NSMenuItem(title: command.title, action: NSSelectorFromString(command.action), keyEquivalent: "")
    item.tag = command.tag
    item.representedObject = command.argument
    item.target = menuItem(for: command)?.target
    return item
  }

  private static func menuItem(for command: Command) -> NSMenuItem? {
    let action = NSSelectorFromString(command.action)
    return NSApp.mainMenu.map(MenuShortcuts.items).flatMap { items in
      items.first { $0.action == action && $0.tag == command.tag && !$0.isHidden } ?? items.first { $0.action == action }
    }
  }
}
