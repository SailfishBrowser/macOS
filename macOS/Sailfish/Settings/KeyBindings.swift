import AppKit
import ComposableArchitecture

// A menu item's key equivalent as the user set it in Settings > Shortcuts; an empty key is a removed shortcut.
struct KeyBinding: Codable, Equatable {
  var key: String
  var modifiers: UInt

  init(key: String, modifiers: NSEvent.ModifierFlags) {
    self.key = key
    self.modifiers = modifiers.rawValue
  }

  init(_ item: NSMenuItem) {
    self.init(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
  }

  var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

  // The keys in the form a press records, for comparing: a capital letter is its lowercase with Shift, and the
  // Function flag AppKit sets on arrows and other function keys is left out.
  var normalized: KeyBinding {
    let lower = key.lowercased()
    var flags = modifierFlags.subtracting(.function)
    if lower != key { flags.insert(.shift) }
    return KeyBinding(key: lower, modifiers: flags)
  }

  // The binding a key press records: the key's unshifted character with the modifiers held, Shift among them, as
  // the menu bar writes ⇧⌘2.
  init?(_ event: NSEvent) {
    guard let characters = event.characters(byApplyingModifiers: []), let character = characters.unicodeScalars.first
    else { return nil }
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let isFunctionKey = (NSF1FunctionKey...NSF35FunctionKey).contains(Int(character.value))
    // The key alone, or with Shift alone, would type into a page; a function key may stand on its own.
    guard isFunctionKey || !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
    self.init(key: characters.lowercased(), modifiers: flags)
  }

  // The press as a key equivalent may also be written: its shifted character without Shift, as ⌘} is ⇧⌘].
  static func shifted(_ event: NSEvent) -> KeyBinding? {
    guard event.modifierFlags.contains(.shift), let characters = event.charactersIgnoringModifiers else { return nil }
    return KeyBinding(
      key: characters, modifiers: event.modifierFlags.intersection([.command, .control, .option])
    ).normalized
  }
}

extension SharedKey where Self == FileStorageKey<[String: KeyBinding]>.Default {
  // Custom shortcuts by menu action, kept across launches.
  static var keyBindings: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "KeyBindings.json")), default: [:]]
  }
}

// Puts the custom shortcuts on the menu bar's items and keeps their defaults for Reset.
@MainActor
enum MenuShortcuts {
  private(set) static var defaults: [String: KeyBinding] = [:]

  // The item's identity for a saved binding: its action and tag, and which of the menu bar's items with that
  // pair it is (New Window and Blank Window share one action).
  static func id(_ item: NSMenuItem) -> String? {
    guard let action = item.action else { return nil }
    let same = NSApp.mainMenu.map(items)?.filter { $0.action == action && $0.tag == item.tag } ?? []
    let index = same.firstIndex { $0 === item } ?? 0
    return "\(NSStringFromSelector(action)):\(item.tag)" + (index == 0 ? "" : "#\(index)")
  }

  static func items(in menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
  }

  // The items Shortcuts rows stand for: the menu bar's own commands, shown or hidden, without the submenus macOS
  // fills in (Services, window tiling) and the Window menu's list of windows.
  static func commands(in menu: NSMenu) -> [NSMenuItem] {
    let system = ["Services", "Move & Resize", "Full Screen Tile"]
    return menu.items.flatMap { $0.submenu.map(items) ?? [] }.filter {
      $0.submenu == nil && !system.contains($0.menu?.title ?? "")
        && $0.action != #selector(NSWindow.makeKeyAndOrderFront(_:)) && id($0).map { !$0.hasPrefix("_") } == true
    }
  }

  // The row a command belongs to. By title, so the same command in another menu (New Tab… in File and Tabs) and its
  // hidden aliases (⌘} for Next Tab, ⌘= for Zoom In, ⌘← for Go Back) share the row's shortcut; the Go to Space items
  // are titled after the spaces, so each is a row of its own.
  static func row(_ item: NSMenuItem) -> String? {
    item.action == #selector(WindowController.selectSpace(_:)) ? id(item) : item.title
  }

  // Each row's id: that of its first command.
  static func owners(in menu: NSMenu) -> [String: String] {
    commands(in: menu).reduce(into: [:]) { owners, item in
      if let row = row(item), owners[row] == nil { owners[row] = id(item) }
    }
  }

  static func apply(to menu: NSMenu) {
    @Shared(.keyBindings) var bindings
    let owners = owners(in: menu)
    for item in commands(in: menu) {
      guard let id = id(item) else { continue }
      if defaults[id] == nil {
        defaults[id] = KeyBinding(item)
      }
      guard let binding = row(item).flatMap({ owners[$0] }).flatMap({ bindings[$0] }) ?? defaults[id] else { continue }
      if item.keyEquivalent != binding.key { item.keyEquivalent = binding.key }
      if item.keyEquivalentModifierMask != binding.modifierFlags { item.keyEquivalentModifierMask = binding.modifierFlags }
    }
  }

  // Whether a press is one of the menu's key equivalents, in either form an item may write it.
  static func binds(_ event: NSEvent, in menu: NSMenu) -> Bool {
    item(for: event, in: menu) != nil
  }

  // The menu's item whose key equivalent a press is, in either form an item may write it.
  static func item(for event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
    guard let binding = KeyBinding(event) else { return nil }
    let forms = [binding] + (KeyBinding.shifted(event).map { [$0] } ?? [])
    return items(in: menu).first { !$0.keyEquivalent.isEmpty && forms.contains(KeyBinding($0).normalized) }
  }

  // The item of another row, if any, whose keys a press would take; forms are the press's normalized bindings.
  static func conflict(_ forms: [KeyBinding], for id: String, in menu: NSMenu) -> NSMenuItem? {
    let owners = owners(in: menu)
    let own = commands(in: menu).filter { item in row(item).flatMap { owners[$0] } == id }
    return items(in: menu).first { item in
      !own.contains { $0 === item } && !item.keyEquivalent.isEmpty && forms.contains(KeyBinding(item).normalized)
    }
  }
}
