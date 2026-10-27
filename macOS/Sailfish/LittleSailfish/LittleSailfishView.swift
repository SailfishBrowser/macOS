import ComposableArchitecture
import EngineCore
import SwiftUI

struct LittleSailfishView: View {
  let store: StoreOf<LittleSailfishFeature>
  let app: StoreOf<AppFeature>
  let openIn: (Space.ID) -> Void

  // The spaces of the Little Sailfish's profile; the first is the last window's selected one.
  private var spaces: [Space] {
    AppFeature.State.littleSailfishSpaces(app.windows, for: store.profileID)
  }

  var body: some View {
    ZStack(alignment: .top) {
      if let tab = store.tab {
        VStack(spacing: 0) {
          bar(tab)
          if let view = Engine.shared.view(tab.id) {
            WebView(view: view).overlay(alignment: .bottomLeading) {
              if let link = Engine.shared.hoveredLinks[tab.id] {
                LinkBubble(url: link, accent: Theme.accent)
              }
            }
          }
        }
        .background(LinearGradient(theme: spaces.first?.theme ?? SpaceTheme()))
        .overlay(alignment: .topTrailing) {
          if !store.isHintShown, store.commandBar == nil {
            LittleSailfishHint { store.send(.dismissHint) }
              .padding(.top, 48)
              .padding(.trailing, 8)
          }
        }
        .overlay(alignment: .topTrailing) {
          // The panel shows and goes in one frame, overlapping the bar from 3 pt below the window's top.
          if store.isOpenInMenuShown {
            OpenInPanel(spaces: spaces) { space in
              store.send(.setOpenInMenu(false))
              openIn(space)
            } close: {
              store.send(.setOpenInMenu(false))
            }
            .padding(.top, 3)
            .padding(.trailing, 4)
          }
        }
      }
      if let commandBar = store.scope(state: \.commandBar, action: \.commandBar.presented) {
        // A click outside the URL editor closes it and keeps the page's URL.
        if store.tab != nil {
          Color.black.opacity(0.001).onTapGesture { store.send(.commandBar(.dismiss)) }
        }
        CommandBarView(store: commandBar, accent: Theme.accent, width: 490, hasCloseButton: true) {
          store.send(.commandBar(.dismiss))
        }
        .padding(.top, store.tab == nil ? 0 : 6)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .environment(\.colorScheme, .dark)
    .ignoresSafeArea()
  }

  private func bar(_ tab: Tab) -> some View {
    HStack(spacing: 8) {
      TrafficLights().frame(width: 66, alignment: .leading)
      HStack(spacing: 0) {
        // The profile shows as a chip only once there is a choice of profiles; else a magnifier.
        if app.profiles.count > 1, let profile = app.profiles[id: store.profileID] {
          profileChip(profile)
        } else {
          Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        }
        Spacer()
        HStack(spacing: 6) {
          if let favicon = tab.favicon {
            Image(nsImage: favicon).resizable().frame(width: 16, height: 16)
          }
          Text(tab.url.domain).font(.system(size: 13)).lineLimit(1)
        }
        Spacer()
        let actions = Engine.shared.extensionActions(tab.id, profile: store.profileID)
        if !actions.isEmpty {
          ExtensionsButton(actions: actions) { Engine.shared.runExtensionAction($0, tab.id, profile: store.profileID) }
        }
        // Shot 64: the link sits on its own lighter square at the field's trailing end.
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(tab.url.absoluteString, forType: .string)
        } label: {
          Image(systemName: "link").font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(width: 36, height: 31)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy Link")
        .padding(.trailing, -6)
      }
      .padding(.horizontal, 6)
      // Shot 64: the field is 31 pt tall.
      .frame(height: 31)
      .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
      .onTapGesture { store.send(.editURL) }
      if let target = spaces.first {
        openInButton(target)
      }
    }
    .padding(.horizontal, 8)
    // The bar is 46 pt tall (the page starts at y 47).
    .frame(height: 46)
  }

  // The profile chip: a menu that moves the page to another profile, remembered for the domain.
  private func profileChip(_ profile: Profile) -> some View {
    Menu {
      Picker("Profile", selection: Binding(get: { store.profileID }, set: { store.send(.switchProfile($0)) })) {
        ForEach(app.profiles) { Text($0.name).tag($0.id) }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      Label(profile.name, systemImage: "face.smiling")
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8).frame(height: 22)
        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  // "Open in <space> ⌘O", with the ⌄ opening the Open In panel.
  private func openInButton(_ target: Space) -> some View {
    HStack(spacing: 0) {
      Button { openIn(target.id) } label: {
        HStack(spacing: 4) {
          Text("Open in").foregroundStyle(.secondary)
          Text(target.name).fontWeight(.semibold)
          Text("⌘O").font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 4).frame(height: 18)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Button { store.send(.setOpenInMenu(!store.isOpenInMenuShown)) } label: {
        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
          .frame(width: 26, height: 30)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("More Spaces")
    }
    .background(Theme.menu, in: RoundedRectangle(cornerRadius: 8))
    .fixedSize()
  }
}

// The extensions button in the Little Sailfish's URL pill: the profile's extension actions in a popover.
private struct ExtensionsButton: View {
  let actions: [ExtensionAction]
  let run: (String) -> ECExtensionPopup?
  @State private var isShown = false

  var body: some View {
    Button { isShown.toggle() } label: {
      Image(systemName: "puzzlepiece.extension").font(.system(size: 13)).foregroundStyle(.secondary)
        .frame(width: 26, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Extensions")
    .popover(isPresented: $isShown, arrowEdge: .bottom) {
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(49), spacing: 6), count: min(actions.count, 4)), spacing: 6) {
        ForEach(actions, id: \.id) { item in
          ActionTile(item: item) { run(item.id) }
        }
      }
      .padding(10)
      .environment(\.colorScheme, .dark)
    }
  }
}

// The first-use hint, hanging under the Open in button.
private struct LittleSailfishHint: View {
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .trailing, spacing: 0) {
      Triangle().fill(Theme.accent).frame(width: 14, height: 7).padding(.trailing, 48)
      HStack(alignment: .top, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Links Open in Little Sailfish").font(.system(size: 13, weight: .semibold))
          Text("Click Open in to move this page in a full window, or ⌘W to close").font(.system(size: 12))
            .opacity(0.9)
        }
        .foregroundStyle(.white)
        Button(action: dismiss) {
          Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(width: 290, alignment: .leading)
      .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
    }
    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
  }
}

private struct Triangle: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

// The Open In panel: a Search Spaces field with a ⌃ that closes it, over the spaces the page can move to,
// the most recent one first. 244 pt wide, a 44 pt field, 46 pt rows with 24 pt icon tiles.
private struct OpenInPanel: View {
  let spaces: [Space]
  let pick: (Space.ID) -> Void
  let close: () -> Void
  @State private var query = ""
  // The row the pointer or the arrow keys picked; the first match until then.
  @State private var highlighted: Space.ID?
  @FocusState private var isFocused: Bool

  private var matches: [Space] {
    let query = query.trimmingCharacters(in: .whitespaces)
    return query.isEmpty ? spaces : spaces.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }

  private var highlightedID: Space.ID? {
    highlighted ?? matches.first?.id
  }

  private func step(_ offset: Int) -> KeyPress.Result {
    let ids = matches.map(\.id)
    guard let current = highlightedID, let index = ids.firstIndex(of: current) else { return .handled }
    highlighted = ids[min(max(index + offset, 0), ids.count - 1)]
    return .handled
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        TextField("", text: $query, prompt: Text("Search Spaces...").foregroundStyle(.secondary))
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .focused($isFocused)
          .onSubmit { highlightedID.map(pick) }
          .onKeyPress(.upArrow) { step(-1) }
          .onKeyPress(.downArrow) { step(1) }
          .onExitCommand(perform: close)
        Button(action: close) {
          Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 12)
      .frame(height: 44)
      Divider()
      VStack(spacing: 0) {
        ForEach(matches) { space in
          Button { pick(space.id) } label: {
            HStack(spacing: 10) {
              SpaceIcon(icon: space.icon)
                .foregroundStyle(Theme.accent(space.theme))
                .frame(width: 24, height: 24)
                .background(Theme.accent(space.theme).opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
              Text(space.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background(highlightedID == space.id ? Theme.hover : .clear)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .onHover { if $0 { highlighted = space.id } }
        }
      }
      .padding(.vertical, 2)
    }
    .frame(width: 244)
    .background(Theme.menu, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1)))
    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    .onAppear { isFocused = true }
    .onChange(of: query) { highlighted = nil }
  }
}
