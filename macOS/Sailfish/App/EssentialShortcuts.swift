import AppKit
import SwiftUI

// Help's Essential Keyboard Shortcuts window, and the menu items the app shows only when they apply.
extension Shell: NSMenuItemValidation {
  @objc func showEssentialShortcuts(_ sender: Any?) {
    let id = NSUserInterfaceItemIdentifier("essentialShortcuts")
    let window = NSApp.windows.first { $0.identifier == id } ?? {
      let window = NSWindow(contentViewController: NSHostingController(rootView: EssentialShortcuts()))
      window.identifier = id
      window.title = "Essential Keyboard Shortcuts"
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      window.center()
      return window
    }()
    window.makeKeyAndOrderFront(nil)
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(setAsDefaultBrowser(_:)):
      item.isHidden = Shell.isDefaultBrowser
      return !item.isHidden
    case #selector(showAllLittleSailfishes(_:)), #selector(closeAllLittleSailfishes(_:)):
      return !littleSailfishes.isEmpty
    // Without a loaded state there is nothing to back up or replace.
    case #selector(restoreData(_:)):
      return store.isLoaded
    case #selector(reopenClosedTab(_:)):
      let controller = NSApp.keyWindow.map { $0.sheetParent ?? $0.parent ?? $0 }?.windowController as? WindowController
      return controller?.store.undoStack.contains(where: \.isClosedPage) == true || !store.closedLittleSailfishes.isEmpty
    default:
      return true
    }
  }
}

// The everyday shortcuts by group, with the keys the menu bar binds them to.
private struct EssentialShortcuts: View {
  private static let groups: [(String, [(String, String)])] = [
    ("Tabs", [
      ("New Tab", "newTab:"), ("Archive Tab", "closeTab:"), ("Restore Last Closed Tab", "reopenClosedTab:"),
      ("Pin or Unpin Tab", "togglePin:"), ("Next Tab", "nextTab:"), ("Previous Tab", "previousTab:"),
      ("Copy URL", "copyURL:"),
    ]),
    ("Spaces and Sidebar", [
      ("Next Space", "nextSpace:"), ("Previous Space", "previousSpace:"),
      ("Show or Hide Sidebar", "toggleSidebarDocking:"), ("Clear Unpinned Tabs", "clearToday:"),
    ]),
    ("Command Bar and Windows", [
      ("Open Command Bar", "openLocation:"), ("Add Split View", "newSplit:"),
      ("New Little Sailfish Window", "newLittleSailfish:"), ("View Library", "toggleLibrary:"), ("Capture", "capture:"),
    ]),
  ]

  var body: some View {
    let items = Self.items(in: NSApp.mainMenu)
    Form {
      ForEach(Self.groups, id: \.0) { group in
        Section(group.0) {
          ForEach(group.1, id: \.1) { shortcut in
            let action = NSSelectorFromString(shortcut.1)
            if let item = items.first(where: { $0.action == action && !$0.isHidden && !$0.keyEquivalent.isEmpty }) {
              LabeledContent(shortcut.0) {
                Text(ShortcutsPane.keys(item))
                  .font(.system(size: 12))
                  .foregroundStyle(.black)
                  .frame(minWidth: 62, minHeight: 22)
                  .background(.white, in: RoundedRectangle(cornerRadius: 4))
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 560)
  }

  private static func items(in menu: NSMenu?) -> [NSMenuItem] {
    (menu?.items ?? []).flatMap { [$0] + items(in: $0.submenu) }
  }
}
