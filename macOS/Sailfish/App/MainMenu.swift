import AppKit
import Sparkle

// The menu bar.
extension Shell {
  func mainMenu() -> NSMenu {
    let appName = ProcessInfo.processInfo.processName
    let menu = NSMenu()
    let help = NSMenu(title: "Help")
    NSApp.helpMenu = help
    let services = NSMenu(title: "Services")
    NSApp.servicesMenu = services
    menu.items = [
      submenu(appName, [
        item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
        checkForUpdates(),
        .separator(),
        item("Settings…", #selector(showSettings(_:)), ",", target: self),
        item("Share \(appName)", #selector(shareSailfish(_:)), target: self),
        item("Set as Default Browser", #selector(setAsDefaultBrowser(_:)), target: self),
        .separator(),
        submenu("Services", [], services),
        .separator(),
        item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
        item("Hide Other Windows", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
        .separator(),
        item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
      ]),
      submenu("File", [
        item("New Tab…", #selector(WindowController.newTab(_:)), "t"),
        item("New Window", #selector(newWindow(_:)), "n", target: self),
        // A new window here always starts blank.
        item("Blank Window", #selector(newWindow(_:)), "n", [.command, .control], target: self),
        item("New Incognito Window", #selector(newIncognitoWindow(_:)), "N", target: self),
        item("New Little Sailfish Window", #selector(newLittleSailfish(_:)), "n", [.command, .option], target: self),
        item("Restore Last Closed Tab", #selector(reopenClosedTab(_:)), "T", target: self),
        .separator(),
        item("Open Command Bar", #selector(WindowController.openLocation(_:)), "l"),
        .separator(),
        item("Close Window", #selector(NSWindow.performClose(_:)), "W"),
        item("Archive Tab", #selector(closeTab(_:)), "w", target: self),
        .separator(),
        item("Capture…", #selector(WindowController.capture(_:)), "2", [.command, .shift]),
        item("Save Page As", #selector(WindowController.savePage(_:)), "S"),
        item("Print", #selector(WindowController.printPage(_:)), "p"),
      ]),
      submenu("Edit", [
        item("Undo", Selector(("undo:")), "z"),
        item("Redo", Selector(("redo:")), "Z"),
        .separator(),
        item("Cut", #selector(NSText.cut(_:)), "x"),
        item("Copy", #selector(NSText.copy(_:)), "c"),
        item("Copy URL", #selector(WindowController.copyURL(_:)), "C"),
        item("Copy URL as Markdown", #selector(WindowController.copyURLAsMarkdown(_:)), "c", [.command, .option, .shift]),
        item("Copy URL as Quote", #selector(WindowController.copyURLAsQuote(_:)), "C", [.command, .control]),
        item("Paste", #selector(NSText.paste(_:)), "v"),
        item("Paste and Match Style", Selector(("pasteAndMatchStyle:")), "V"),
        item("Paste URL as New Tab", #selector(WindowController.pasteAsNewTab(_:)), "v", [.command, .option]),
        item("Delete", #selector(NSText.delete(_:))),
        item("Select All", #selector(NSText.selectAll(_:)), "a"),
        .separator(),
        submenu("Find", [
          item("Find…", #selector(WindowController.find(_:)), "f"),
          item("Find Next", #selector(WindowController.findNext(_:)), "g"),
          item("Find Previous", #selector(WindowController.findPrevious(_:)), "G"),
          item("Use Selection to Find", #selector(WindowController.useSelectionForFind(_:))),
          item("Jump to Selection", #selector(WindowController.jumpToSelection(_:)), "j"),
        ]),
        submenu("Spelling and Grammar", [
          item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
          item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
          .separator(),
          item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
          item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))),
          item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))),
        ]),
        submenu("Substitutions", [
          item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))),
          .separator(),
          item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))),
          item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))),
          item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))),
          item("Smart Links", #selector(NSTextView.toggleAutomaticLinkDetection(_:))),
          item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))),
        ]),
        submenu("Transformations", [
          item("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))),
          item("Make Lower Case", #selector(NSResponder.lowercaseWord(_:))),
          item("Capitalize", #selector(NSResponder.capitalizeWord(_:))),
        ]),
        submenu("Speech", [
          item("Start Speaking", #selector(NSTextView.startSpeaking(_:))),
          item("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))),
        ]),
      ]),
      submenu("View", [
        item("Show Sidebar", #selector(WindowController.toggleSidebarDocking(_:)), "s"),
        item("Collapse Pinned Tabs", #selector(WindowController.togglePinnedSection(_:))),
        .separator(),
        item("Stop Loading", #selector(WindowController.stopLoading(_:)), "."),
        item("Refresh the Page", #selector(WindowController.reload(_:)), "r"),
        item("Force Refresh the Page", #selector(WindowController.reloadBypassingCache(_:)), "R"),
        .separator(),
        item("Show Reader View", #selector(WindowController.toggleReader(_:)), "r", [.command, .option]),
        .separator(),
        item("Add Split View", #selector(WindowController.newSplit(_:)), "=", [.control, .shift]),
        item("Close this Split Pane", #selector(WindowController.closeSplitPane(_:)), "-", [.control, .shift]),
        .separator(),
        item("Zoom to Actual Size", #selector(WindowController.resetZoom(_:)), "0"),
        item("Zoom In", #selector(WindowController.zoomIn(_:)), "+"),
        hidden(item("Zoom In", #selector(WindowController.zoomIn(_:)), "=")),
        item("Zoom Out", #selector(WindowController.zoomOut(_:)), "-"),
        .separator(),
        item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        .separator(),
        submenu("Developer", [
          item("JavaScript Console", #selector(WindowController.showJavaScriptConsole(_:)), "j", [.command, .option]),
          item("Inspect Elements", #selector(WindowController.inspectElements(_:)), "c", [.command, .option]),
          item("View Source", #selector(WindowController.viewSource(_:)), "u", [.command, .option]),
        ]),
      ]),
      submenu("Spaces", [
        item("New Space…", #selector(WindowController.newSpace(_:))),
        item("Edit Theme…", #selector(WindowController.editTheme(_:))),
        item("Rename Space", #selector(WindowController.renameSpace(_:))),
        item("Change Profile", #selector(WindowController.changeProfile(_:))),
        // WindowController titles it Hide or Show Space Header.
        item("Hide Space Header", #selector(WindowController.toggleSpaceHeader(_:))),
        .separator(),
        item("Next Space", #selector(WindowController.nextSpace(_:)), arrow(NSRightArrowFunctionKey), [.command, .option]),
        item("Previous Space", #selector(WindowController.previousSpace(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option]),
        .separator(),
        item("Expand All Folders", #selector(WindowController.expandAllFolders(_:))),
        item("Collapse All Folders", #selector(WindowController.collapseAllFolders(_:))),
        item("Close This Folder", #selector(WindowController.closeThisFolder(_:))),
        .separator(),
      ] + (1...9).map {
        // WindowController names these after the window's spaces, hiding those it has none for.
        let item = item("", #selector(WindowController.selectSpace(_:)), "\($0)", .control)
        item.tag = $0 - 1
        return hidden(item)
      } + [
        .separator(),
        item("Manage Spaces…", #selector(WindowController.manageSpaces(_:))),
      ]),
      submenu("Tabs", [
        item("New Tab…", #selector(WindowController.newTab(_:)), "t"),
        item("Pin Tab", #selector(WindowController.togglePin(_:)), "d"),
        // While a Little Sailfish is key: Open in <space> ⌘O, and the hidden Show Little Sailfish Open In Menu ⇧⌘O.
        item("Open in Space", #selector(LittleSailfishWindowController.openInSpace(_:)), "o"),
        hidden(item("Show Little Sailfish Open In Menu", #selector(LittleSailfishWindowController.showOpenInMenu(_:)), "O")),
        item("Duplicate", #selector(WindowController.duplicateTab(_:))),
        item("Rename Current Tab", #selector(WindowController.renameCurrentTab(_:))),
        item("Reset Tab to Original URL", #selector(WindowController.resetTabToPinnedURL(_:))),
        item("New Folder…", #selector(WindowController.newFolder(_:))),
        .separator(),
        item("Next Tab", #selector(WindowController.nextTab(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]),
        item("Previous Tab", #selector(WindowController.previousTab(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]),
        hidden(item("Next Tab", #selector(WindowController.nextTab(_:)), "}")),
        hidden(item("Previous Tab", #selector(WindowController.previousTab(_:)), "{")),
        // The recent-tab switcher: ⌃Tab steps to older tabs last shown, ⌃⇧Tab and ⌃` back toward newer ones.
        hidden(item("Cycle Tab Forward", #selector(WindowController.cycleTabForward(_:)), "\t", .control)),
        hidden(item("Cycle Tab Backward", #selector(WindowController.cycleTabBackward(_:)), "\t", [.control, .shift])),
        hidden(item("Cycle Tab Backward", #selector(WindowController.cycleTabBackward(_:)), "`", .control)),
      ] + (1...9).map {
        // ⌘1-⌘8 go to the sidebar's nth item and ⌘9 to its last.
        hidden(tagged(item("Go to Sidebar Item \($0)", #selector(WindowController.selectSidebarItem(_:)), "\($0)"), $0 - 1))
      } + [
        item("Reveal Tab in Sidebar", #selector(WindowController.revealTabInSidebar(_:))),
        .separator(),
        item("Expand Current Split", #selector(WindowController.expandCurrentSplit(_:))),
        item("Separate Page from Split View", #selector(WindowController.separatePane(_:))),
        .separator(),
        item("Clear Unpinned Tabs", #selector(WindowController.clearToday(_:)), "K"),
        // Kept in Tabs, under Clear Today.
        item("Reset all tabs in this Space", #selector(WindowController.resetSpaceTabs(_:))),
      ]),
      submenu("Archive", [
        item("Go Back", #selector(WindowController.goBack(_:)), "["),
        item("Go Forward", #selector(WindowController.goForward(_:)), "]"),
        hidden(item("Go Back", #selector(WindowController.goBackWithArrow(_:)), arrow(NSLeftArrowFunctionKey))),
        hidden(item("Go Forward", #selector(WindowController.goForwardWithArrow(_:)), arrow(NSRightArrowFunctionKey))),
        .separator(),
        item("View History", #selector(WindowController.viewHistory(_:)), "y"),
        tagged(item("View Archive", #selector(WindowController.openLibrary(_:))), 3),
        .separator(),
        item("Clear Archive", #selector(WindowController.clearArchive(_:))),
      ]),
      submenu("Extensions", [
        item("Add Extension…", #selector(WindowController.addExtension(_:))),
        item("Manage Extensions…", #selector(WindowController.showExtensions(_:))),
      ]),
      submenu("Window", [
        // A Little Sailfish's; checked while Little Sailfish windows stay above other windows.
        item("Stay On Top", #selector(LittleSailfishWindowController.toggleStaysOnTop(_:))),
        item("Minimize Window", #selector(NSWindow.performMiniaturize(_:)), "m"),
        alternate(item("Minimize All", #selector(NSApplication.miniaturizeAll(_:)), "m", [.command, .option])),
        item("Zoom", #selector(NSWindow.performZoom(_:))),
        .separator(),
        item("Open Library…", #selector(WindowController.toggleLibrary(_:)), "L"),
        item("View Downloads…", #selector(WindowController.openLibrary(_:)), "J"),
        tagged(item("View Media…", #selector(WindowController.openLibrary(_:))), 4),
        .separator(),
        item("Show Little Sailfish Windows", #selector(showAllLittleSailfishes(_:)), target: self),
        item("Close Little Sailfish Windows", #selector(closeAllLittleSailfishes(_:)), target: self),
        .separator(),
        item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
      ]),
      submenu("Help", [
        item("Essential Keyboard Shortcuts", #selector(showEssentialShortcuts(_:)), target: self),
        item("Restore Data…", #selector(restoreData(_:)), target: self),
        submenu("Troubleshooting", [
          item("Reveal \(appName) Data", #selector(revealData(_:)), target: self),
          item("Copy \(appName) Info", #selector(copyInfo(_:)), target: self),
        ]),
      ], help),
    ]
    NSApp.windowsMenu = menu.items[8].submenu
    menu.items[5].submenu?.delegate = self
    return menu
  }

  // The Dock menu, under the window list AppKit adds: new windows and the Little Sailfish windows.
  // The Dock serializes each item's isEnabled rather than validating, so syncLittleSailfishes enables the Little Sailfish items.
  func dockMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.items = [
      item("New Window", #selector(newWindow(_:)), target: self),
      item("New Incognito Window", #selector(newIncognitoWindow(_:)), target: self),
      item("Show Little Sailfish Windows", #selector(showAllLittleSailfishes(_:)), target: self),
      item("Close Little Sailfish Windows", #selector(closeAllLittleSailfishes(_:)), target: self),
    ]
    return menu
  }

  // Debug builds run no updater, so there the item has no target and stays disabled.
  private func checkForUpdates() -> NSMenuItem {
    let item = item("Check for Updates…", #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
    #if !DEBUG
      item.target = updater.controller
    #endif
    return item
  }

  private func submenu(_ title: String, _ items: [NSMenuItem], _ menu: NSMenu? = nil) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = menu ?? NSMenu(title: title)
    item.submenu?.items = items
    return item
  }

  private func item(
    _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
    target: AnyObject? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = target
    return item
  }

  private func arrow(_ key: Int) -> String {
    String(UnicodeScalar(UInt16(key))!)
  }

  private func tagged(_ item: NSMenuItem, _ tag: Int) -> NSMenuItem {
    item.tag = tag
    return item
  }

  // Shown in place of the item above it while Option is held.
  private func alternate(_ item: NSMenuItem) -> NSMenuItem {
    item.isAlternate = true
    return item
  }

  private func hidden(_ item: NSMenuItem) -> NSMenuItem {
    item.isHidden = true
    item.allowsKeyEquivalentWhenHidden = true
    return item
  }
}
