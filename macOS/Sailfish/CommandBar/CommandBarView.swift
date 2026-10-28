import ComposableArchitecture
import SwiftUI

private typealias Style = Theme.CommandBar

struct CommandBarView: View {
  @Bindable var store: StoreOf<CommandBarFeature>
  let accent: Color
  // Little Sailfish's panel is narrower, with a close button for the info button.
  var width = Style.width
  var hasCloseButton = false
  let dismiss: () -> Void
  @FocusState private var isFocused: Bool
  @State private var backspaceMonitor: Any?
  @State private var clickMonitor: Any?
  // The panel's frame in the window, top-left origin, for telling a click outside it from one on it.
  @State private var panelFrame = CGRect.zero
  @Environment(\.displayScale) private var displayScale

  // The chip before the field: Actions, or the site search Tab entered.
  private var mode: String? {
    store.isActions ? "Actions" : store.keyword?.name
  }

  private var selected: CommandBarFeature.Suggestion? {
    store.suggestions.indices.contains(store.selection) ? store.suggestions[store.selection] : nil
  }

  // Arrow keys show the selected suggestion in the field without changing the query.
  private var text: Binding<String> {
    Binding(
      get: { store.selection > 0 ? selected?.fill ?? store.query : store.query + store.inline },
      set: {
        store.send(.queryChanged($0))
        // While the keystroke is handled, so no frame shows the typed text without its completion.
        selectInline()
      }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: Style.textSpacing) {
        // The selected page's favicon replaces the magnifier once the field shows text.
        SuggestionIcon(
          favicon: store.isActions || text.wrappedValue.isEmpty ? nil : selected.flatMap { favicon($0) },
          systemName: store.isActions || text.wrappedValue.isEmpty ? "magnifyingglass" : selected?.icon ?? "magnifyingglass",
          size: 12, weight: .semibold, faviconSize: 16)
          .foregroundStyle(Style.fieldIcon)
        if let mode {
          Text(mode).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 10).frame(height: 23)
            .background(accent, in: Capsule())
        }
        TextField(
          "", text: text,
          // Measured on a Retina screen: the typed alphabet is 485 px wide with 4.5 px
          // stems at 2x, which is SF Pro Medium at 18 pt (Regular measures 470 px and 3.6 px stems).
          prompt: Text(mode == nil ? "Search or Enter URL..." : "Search...").font(.system(size: 18, weight: .medium))
            .foregroundStyle(Style.placeholder)
        )
        .textFieldStyle(.plain)
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(Style.text)
        .focused($isFocused)
        .onSubmit { store.send(.submit(store.selection)) }
        .onKeyPress(.upArrow) {
          store.send(.moveSelection(-1))
          return .handled
        }
        .onKeyPress(.downArrow) {
          store.send(.moveSelection(1))
          return .handled
        }
        .onKeyPress(.tab) {
          guard store.keywordHint != nil || store.offersActions else { return .ignored }
          store.send(.enterKeyword)
          return .handled
        }
        // Space after a site's keyword enters its search too, as in Chrome.
        .onKeyPress(.space) {
          guard store.keywordHint != nil, !store.query.contains(" ") else { return .ignored }
          store.send(.enterKeyword)
          return .handled
        }
        .onExitCommand { if mode == nil { dismiss() } else { store.send(.leaveKeyword) } }
        if let hint = store.keywordHint {
          // Chrome's "Search Wikipedia [Tab]" hint: 13 pt medium, 9 pt before a 24 pt keycap.
          HStack(spacing: 9) {
            Text("Search \(hint.name)").font(.system(size: 13, weight: .medium)).foregroundStyle(Style.detail)
            Text("Tab").font(.system(size: 13, weight: .medium)).foregroundStyle(Style.keycapText)
              .padding(.horizontal, 4).frame(height: 24)
              .background(Style.keycap, in: RoundedRectangle(cornerRadius: 4))
          }
        } else if hasCloseButton {
          // Clears the field, keeping the panel open; with nothing left to clear it closes the panel.
          Button {
            if store.query.isEmpty { dismiss() } else { store.send(.queryChanged("")) }
          } label: {
            // The close glyph: 10 pt of ink.
            Image(systemName: "xmark")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(Style.closeGlyph)
              .frame(width: 24, height: 24)
              .background(Style.fill, in: RoundedRectangle(cornerRadius: 6))
          }
          .buttonStyle(.plain)
        } else {
          // The info button opens the keyboard shortcuts.
          Button {
            dismiss()
            AppCommands.perform(Command(title: "Edit Keyboard Shortcuts", symbol: "", action: "showSettings:", tag: SettingsPane.shortcuts.rawValue))
          } label: {
            Image(systemName: "info.circle").font(.system(size: 17, weight: .medium)).foregroundStyle(Style.infoGlyph)
              .frame(width: 24, height: 24)
              .background(Style.infoFill, in: Circle())
          }
          .buttonStyle(.plain)
          .help("Keyboard Shortcuts")
        }
      }
      .padding(.leading, Style.iconLeading)
      // The info button and Tab keycap end 22 pt from the panel's edge.
      .padding(.trailing, 22)
      .frame(height: Style.inputHeight)

      if !store.suggestions.isEmpty {
        Rectangle().fill(Style.separator).frame(height: 1 / displayScale).padding(.horizontal, 12)
        VStack(spacing: Style.rowSpacing) {
          ForEach(Array(store.suggestions.enumerated()), id: \.offset) { index, suggestion in
            SuggestionRow(
              suggestion: suggestion, favicon: favicon(suggestion), isSelected: index == store.selection,
              accent: accent, panelWidth: width, isRecent: store.editedTab != nil || store.showsTabsAsRecents,
              space: { if case let .tab(tab) = suggestion { store.spaceNames[tab.id] } else { nil } }(),
              isCurrent: { if case let .tab(tab) = suggestion { tab.id == store.editing } else { false } }(),
              remove: suggestion.isRemovable ? { store.send(.removeSuggestion(index)) } : nil
            )
            .onTapGesture { store.send(.submit(index)) }
          }
        }
        .padding(.horizontal, Style.inset)
        .padding(.top, Style.rowsTop)
        .padding(.bottom, Style.rowsBottom)
      }
    }
    .frame(width: width)
    // The shadow is cast by the fill alone, so the rim and the rows do not stack their own. A Little Sailfish's window
    // draws its own shadow.
    .background {
      ZStack {
        // Cut out under the panel, so the page shows through it undarkened.
        RoundedRectangle(cornerRadius: Style.radius).fill(.black)
          .shadow(color: .black.opacity(hasCloseButton ? 0 : Style.shadowOpacity), radius: Style.shadowRadius, y: Style.shadowY)
          .mask {
            Rectangle().padding(-4 * Style.shadowRadius)
              .overlay(RoundedRectangle(cornerRadius: Style.radius).blendMode(.destinationOut))
              .compositingGroup()
          }
        RoundedRectangle(cornerRadius: Style.radius).fill(.ultraThinMaterial)
        RoundedRectangle(cornerRadius: Style.radius).fill(Style.background)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: Style.radius - 1 / displayScale).strokeBorder(Style.innerLine, lineWidth: 1)
        .padding(1 / displayScale))
    .overlay(RoundedRectangle(cornerRadius: Style.radius).strokeBorder(Style.outerLine, lineWidth: 1 / displayScale))
    // A site search or Actions glows in its color.
    .shadow(color: accent.opacity(mode == nil ? 0 : 0.6), radius: 24)
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panelFrame = $0 }
    .onAppear {
      isFocused = true
      select(in: store.query, NSRange(location: 0, length: store.query.utf16.count))
      store.send(.appeared)
      // A click anywhere else in the window closes the bar and goes on to what was clicked, as in Arc. A Little
      // Sailfish bar has its close button instead.
      if hasCloseButton { return }
      clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
        guard let window = event.window, window.isKeyWindow, let content = window.contentView else { return event }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        if !panelFrame.contains(point) { dismiss() }
        return event
      }
      // The field editor takes Backspace and ⌘Return before onKeyPress. Backspace at the start leaves keyword mode,
      // with ⌘⌥ it removes the selected suggestion, and ⌘Return opens the row in a Little Sailfish.
      backspaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
          store.send(.submitInLittleSailfish(store.selection))
          return nil
        }
        guard event.keyCode == 51 else { return event }
        if event.modifierFlags.intersection([.command, .option]) == [.command, .option] {
          store.send(.removeSuggestion(store.selection))
          return nil
        }
        guard mode != nil, store.query.isEmpty else { return event }
        store.send(.leaveKeyword)
        return nil
      }
    }
    .onDisappear {
      backspaceMonitor.map(NSEvent.removeMonitor)
      clickMonitor.map(NSEvent.removeMonitor)
    }
    .onChange(of: store.inline) { selectInline() }
    // New matches redraw the field, which drops the selection of an inline completion kept while typing.
    .onChange(of: store.matchesQuery) { selectInline() }
    .onChange(of: store.selection) {
      // The part of the suggestion after what was typed is selected.
      let shown = text.wrappedValue
      let typed = shown.lowercased().hasPrefix(store.query.lowercased()) ? store.query.utf16.count : 0
      select(in: shown, NSRange(location: typed, length: shown.utf16.count - typed))
    }
  }

  private func selectInline() {
    guard !store.inline.isEmpty else { return }
    let typed = store.query.utf16.count
    select(in: store.query + store.inline, NSRange(location: typed, length: store.inline.utf16.count))
  }

  // Selects in the field editor once SwiftUI has shown `text` there. SwiftUI's TextField selection binding
  // crashes when its indices outlive the text they were made for.
  private func select(in text: String, _ range: NSRange) {
    func apply() -> Bool {
      guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, text.hasPrefix(editor.string) else { return false }
      // SwiftUI would show an inline completion kept while typing only on a later update, a frame or more late.
      let shown = (editor.string as NSString).length
      if shown < text.utf16.count {
        editor.replaceCharacters(in: NSRange(location: shown, length: 0), with: String(text.utf16.dropFirst(shown))!)
      }
      editor.selectedTextAttributes = [.backgroundColor: NSColor(Style.textSelection)]
      editor.insertionPointColor = NSColor(red: 0x34 / 255, green: 0x78 / 255, blue: 0xF6 / 255, alpha: 1)
      editor.setSelectedRange(range)
      return true
    }
    if !apply() { DispatchQueue.main.async { _ = apply() } }
  }

  // History's favicon for the page, else that of an open tab on the same site.
  private func favicon(_ suggestion: CommandBarFeature.Suggestion) -> NSImage? {
    switch suggestion {
    case let .tab(tab): tab.favicon ?? store.favicons[tab.url]
    case let .match(match):
      match.type == .search
        ? nil : store.favicons[match.url] ?? store.tabs.first { $0.url.host() == match.url.host() }?.favicon
    case .command, .calculation: nil
    }
  }
}

private struct SuggestionIcon: View {
  let favicon: NSImage?
  let systemName: String
  var size: CGFloat = 13
  var weight: Font.Weight = .medium
  // A row's favicon is drawn at 14 pt and the field's at 16 pt.
  var faviconSize: CGFloat = 14

  var body: some View {
    Group {
      if let favicon {
        Image(nsImage: favicon).resizable().frame(width: faviconSize, height: faviconSize)
      } else {
        Image(systemName: systemName).font(.system(size: size, weight: weight))
      }
    }
    .frame(width: 16, height: 16)
  }
}

private struct SuggestionRow: View {
  let suggestion: CommandBarFeature.Suggestion
  let favicon: NSImage?
  let isSelected: Bool
  let accent: Color
  // Sets the title's and the detail's widest.
  let panelWidth: CGFloat
  // ⌘L lists recent tabs like history, without "Switch to Tab".
  let isRecent: Bool
  // The space of a tab in another space, shown for "Switch to Tab".
  let space: String?
  // The page ⌘L is editing, shown by title only.
  let isCurrent: Bool
  // Removes the suggestion, for a history row's hover X.
  let remove: (() -> Void)?
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: Style.textSpacing) {
      SuggestionIcon(favicon: favicon, systemName: suggestion.icon)
        .foregroundStyle(isCommand && isSelected ? accent : isSelected ? .white : Style.icon)
        .background {
          // Favicons and commands sit on a tile, white in the selected row.
          if isSelected && (favicon != nil || isCommand) {
            // A white favicon would vanish on the white tile, so it gets a dark one.
            // The tile: 24 pt, radius 4.
            RoundedRectangle(cornerRadius: 4).fill(favicon?.isLight == true ? Style.infoFill : .white)
              .frame(width: 24, height: 24)
          } else if isCommand {
            RoundedRectangle(cornerRadius: 4).fill(Style.keycap).frame(width: 24, height: 24)
          }
        }
      // Titles and details are 13 pt medium; the detail is white at 0.5 on the selected row.
      TitleDetailLayout(
        titleWidth: 0.648 * (panelWidth - 2 * Style.inset), detailWidth: 0.383 * (panelWidth - 2 * Style.inset)
      ) {
        Text(title).truncationMode(.tail)
          .foregroundStyle(isSelected ? .white : Style.title)
        if let detail {
          Text(" — \(detail)").truncationMode(.middle)
            .foregroundStyle(isSelected ? Color.white.opacity(0.5) : Style.detail)
        }
      }
      .font(.system(size: 13, weight: .medium))
      .lineLimit(1)
      Spacer(minLength: 0)
      if case let .command(command) = suggestion, !command.shortcut.isEmpty {
        Text(command.shortcut.map(String.init).joined(separator: " "))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(isSelected ? accent : Style.detail)
          .padding(.horizontal, 6).frame(height: 22)
          .background(isSelected ? .white : Style.keycap, in: RoundedRectangle(cornerRadius: 4))
      }
      if let remove, isHovering {
        Button(action: remove) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isSelected ? .white : Style.title)
            .frame(width: 24, height: 24)
            .background(Style.fill, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove from suggestions")
      }
      if case .tab = suggestion, !isRecent {
        // 13 pt medium, 9 pt before a 24 pt arrow tile.
        HStack(spacing: 9) {
          Text(space ?? "Switch to Tab").font(.system(size: 13, weight: .medium))
            .foregroundStyle(isSelected ? .white : Style.detail)
          Image(systemName: "arrow.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isSelected ? accent : Style.title)
            .frame(width: 24, height: 24)
            .background(isSelected ? .white : Style.keycap, in: RoundedRectangle(cornerRadius: 6))
        }
      }
    }
    .padding(.leading, Style.iconLeading - Style.inset)
    .padding(.trailing, 14)
    .frame(height: Style.rowHeight)
    .background(
      isSelected ? accent : isHovering ? Style.hover : .clear, in: RoundedRectangle(cornerRadius: 6)
    )
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
  }

  private var isCommand: Bool {
    if case .command = suggestion { true } else { false }
  }

  private var title: String {
    switch suggestion {
    case let .tab(tab): tab.title
    case let .command(command): command.title
    case let .match(match): match.type == .search || match.description.isEmpty ? match.contents : match.description
    case let .calculation(expression, result): "\(expression) = \(result)"
    }
  }

  private var detail: String? {
    switch suggestion {
    case let .tab(tab): isRecent && !isCurrent ? tab.url.displayString : nil
    case let .match(match): match.type == .search ? nil : match.url.displayString
    case .command, .calculation: nil
    }
  }
}

// A row's title truncates at its end and the " — detail" in its middle, each within its own widest: 64.8% and
// 38.3% of the row. A truncated title keeps its whole width.
private struct TitleDetailLayout: Layout {
  let titleWidth: CGFloat
  let detailWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let widths = widths(proposal.width ?? .infinity, subviews)
    let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
    return CGSize(width: widths.reduce(0, +), height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    for (subview, width) in zip(subviews, widths(bounds.width, subviews)) {
      subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: nil))
      x += width
    }
  }

  private func widths(_ available: CGFloat, _ subviews: Subviews) -> [CGFloat] {
    var left = available
    return zip(subviews, [titleWidth, detailWidth]).map { subview, widest in
      let width = min(subview.sizeThatFits(.unspecified).width, widest, left)
      left -= width
      return width
    }
  }
}

extension CommandBarFeature.Suggestion {
  // The glyph for a row without a favicon: a clock for history.
  var icon: String {
    if case let .command(command) = self { return command.symbol }
    if case .calculation = self { return "equal.square" }
    guard case let .match(match) = self else { return "globe" }
    switch match.type {
    case .search: return "magnifyingglass"
    case .history: return "clock"
    default: return "globe"
    }
  }

  // The text the field shows while this suggestion is selected; a command leaves the typed text.
  var fill: String? {
    switch self {
    case let .tab(tab): tab.url.displayString
    case let .match(match): match.type == .search ? match.contents : match.url.displayString
    case .command, .calculation: nil
    }
  }
}

extension URL {
  // The host without "www.".
  var domain: String {
    host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? absoluteString
  }

  var displayString: String {
    path() == "/" ? domain : domain + path()
  }
}

extension NSImage {
  // Whether the opaque pixels are mostly light, from an 8x8 sample.
  var isLight: Bool {
    guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 8, height: 8))
    let pixels = UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 256)
    var light = 0.0
    var opaque = 0.0
    for i in stride(from: 0, to: 256, by: 4) where pixels[i + 3] > 128 {
      opaque += 1
      light += (Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / 3 > 200 ? 1 : 0
    }
    return opaque > 0 && light / opaque > 0.6
  }
}
