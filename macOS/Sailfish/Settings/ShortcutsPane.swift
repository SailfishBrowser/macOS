import AppKit
import ComposableArchitecture
import SwiftUI

// The Shortcuts pane: the menu bar's key equivalents, searchable by name or keys, with the custom ones listed
// first. A click on a row records the next keys pressed as its shortcut.
struct ShortcutsPane: View {
  @State private var query = ""
  @Shared(.keyBindings) private var bindings
  // The row recording keys, and the reason the last keys were refused.
  @State private var recording: String?
  @State private var refusal: String?
  @State private var monitor: Any?
  @State private var resignObserver: (any NSObjectProtocol)?

  var body: some View {
    let shortcuts = Self.shortcuts(in: NSApp.mainMenu).filter {
      query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.keys.localizedCaseInsensitiveContains(query)
    }
    let custom = shortcuts.filter { bindings[$0.id] != nil }
    VStack(alignment: .trailing, spacing: 10) {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Search", text: $query).textFieldStyle(.plain)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color.primary.opacity(0.04))
        Divider()
        ScrollView {
          VStack(spacing: 0) {
            if !custom.isEmpty {
              section("Custom Shortcuts", custom)
            }
            section("Default Shortcuts", shortcuts.filter { bindings[$0.id] == nil })
          }
        }
      }
      .settingsCard()
      Button("Reset All Shortcuts") {
        $bindings.withLock { $0 = [:] }
        NSApp.mainMenu.map(MenuShortcuts.apply)
      }
      .disabled(bindings.isEmpty)
    }
    .padding(.vertical, 20)
    .padding(.horizontal, 64)
    .onDisappear { stopRecording() }
  }

  private func section(_ title: String, _ shortcuts: [Shortcut]) -> some View {
    VStack(spacing: 0) {
      Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 28)
      Divider()
      ForEach(shortcuts) { shortcut in
        row(shortcut)
        Divider().padding(.horizontal, 24)
      }
    }
  }

  private func row(_ shortcut: Shortcut) -> some View {
    let isRecording = recording == shortcut.id
    return HStack {
      Text(shortcut.title).font(.system(size: 13))
      Spacer()
      // The chip is outlined in the accent while it records; the keys stay until new ones are pressed.
      Text(isRecording ? refusal ?? shortcut.keys : shortcut.keys)
        .font(.system(size: 12))
        .foregroundStyle(isRecording ? Theme.accent : .black)
        .padding(.horizontal, 8)
        .frame(minWidth: 62, minHeight: 22)
        .background(.white, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent.opacity(isRecording ? 1 : 0), lineWidth: 1.5))
    }
    .padding(.horizontal, 24)
    .frame(height: 48)
    .contentShape(Rectangle())
    .onTapGesture { isRecording ? stopRecording() : record(shortcut.id) }
    .contextMenu {
      Button("Remove Shortcut") { set(KeyBinding(key: "", modifiers: []), for: shortcut.id) }
        .disabled(shortcut.keys == "---")
      Button("Reset Shortcut to Default") { set(nil, for: shortcut.id) }
        .disabled(bindings[shortcut.id] == nil)
    }
  }

  // Takes the next keys pressed in the Settings window as the row's shortcut; Esc keeps the old one, and so does
  // leaving the window.
  private func record(_ id: String) {
    stopRecording()
    recording = id
    refusal = nil
    let window = NSApp.keyWindow
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: window, queue: .main
    ) { _ in MainActor.assumeIsolated { stopRecording() } }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard recording == id, event.window === window else { return event }
      if event.keyCode == 53 {
        stopRecording()
        return nil
      }
      guard let binding = KeyBinding(event) else {
        refusal = "Add ⌘, ⌃ or ⌥"
        return nil
      }
      let forms = [binding] + (KeyBinding.shifted(event).map { [$0] } ?? [])
      // Keys another row holds move to this one and leave that row without any, as Arc's do; keys of an item
      // that is not a row (the system's) are refused.
      if let menu = NSApp.mainMenu, let taken = MenuShortcuts.conflict(forms, for: id, in: menu) {
        guard let other = MenuShortcuts.row(taken).flatMap({ MenuShortcuts.owners(in: menu)[$0] }) else {
          refusal = "Used by \(taken.title)"
          return nil
        }
        $bindings.withLock { $0[other] = KeyBinding(key: "", modifiers: []) }
      }
      set(MenuShortcuts.defaults[id].map { forms.contains($0.normalized) } == true ? nil : binding, for: id)
      stopRecording()
      return nil
    }
  }

  private func stopRecording() {
    monitor.map(NSEvent.removeMonitor)
    monitor = nil
    resignObserver.map(NotificationCenter.default.removeObserver)
    resignObserver = nil
    recording = nil
    refusal = nil
  }

  private func set(_ binding: KeyBinding?, for id: String) {
    $bindings.withLock { $0[id] = binding }
    NSApp.mainMenu.map(MenuShortcuts.apply)
  }

  struct Shortcut: Hashable, Identifiable {
    let id: String
    let title: String
    let keys: String
  }

  // The menu bar's commands, one per row: the shown ones, and the ones with keys but no menu item of their own
  // (Cycle Tab Forward, Cycle Tab Backward), which Arc lists too. The hidden aliases of a shown row and the Go to
  // Space items stay off the list.
  private static func shortcuts(in menu: NSMenu?) -> [Shortcut] {
    guard let menu else { return [] }
    let owners = MenuShortcuts.owners(in: menu)
    var seen = Set<String>()
    let commands = MenuShortcuts.commands(in: menu)
    return (commands.filter { !$0.isHidden } + commands.filter { $0.isHidden && $0.action != #selector(WindowController.selectSpace(_:)) })
      .compactMap { item in
        guard let row = MenuShortcuts.row(item), let id = owners[row], seen.insert(row).inserted else { return nil }
        return Shortcut(id: id, title: item.title, keys: keys(item))
      }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  // "---" stands for a shortcut with no keys.
  static func keys(_ item: NSMenuItem) -> String {
    let key = item.keyEquivalent
    guard !key.isEmpty else { return "---" }
    let modifiers = item.keyEquivalentModifierMask
    var names = [
      NSUpArrowFunctionKey: "↑", NSDownArrowFunctionKey: "↓", NSLeftArrowFunctionKey: "←", NSRightArrowFunctionKey: "→",
      NSDeleteFunctionKey: "⌦", NSHomeFunctionKey: "↖", NSEndFunctionKey: "↘", NSPageUpFunctionKey: "⇞", NSPageDownFunctionKey: "⇟",
    ].reduce(into: ["\t": "⇥", "\r": "↩", "\u{1B}": "⎋", "\u{8}": "⌫", "\u{7F}": "⌫", " ": "Space"]) { $0[String(UnicodeScalar(UInt16($1.key))!)] = $1.value }
    for number in 1...20 {
      names[String(UnicodeScalar(UInt16(NSF1FunctionKey + number - 1))!)] = "F\(number)"
    }
    return (modifiers.contains(.function) ? "fn " : "") + (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
      + (modifiers.contains(.shift) || key != key.lowercased() ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
      + (names[key] ?? key.uppercased())
  }
}
