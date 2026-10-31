import AppKit
import SwiftUI

// The "Create a Space" panel, shown in place of the sidebar's content.
struct SpaceEditor: View {
  let title: String
  @State var name: String
  @State var icon: String
  @State var theme: SpaceTheme
  // The theme as the editor opened, for the picker's Reset to original colors and Original Saturation.
  private let original: SpaceTheme
  // nil when editing an existing space, whose profile is fixed.
  let profiles: [Profile]?
  @State var profile: Profile.ID
  let done: (_ name: String, _ icon: String, _ theme: SpaceTheme, _ profile: Profile.ID) -> Void
  let cancel: () -> Void
  // The picker opened at once for Edit Theme Color….
  var opening: Opening? = nil
  // New Profile… in the Profile pop-up: a dialog for the name; the new profile is then the one picked.
  var createProfile: ((String) -> Void)? = nil
  // The confirm button's title, else Save for an existing space and Create Space for a new one.
  var confirm: String? = nil
  @State private var isPickingIcon = false
  @State private var isPickingTheme = false
  @State private var awaitsNewProfile = false

  enum Opening {
    case theme
  }

  init(
    title: String, name: String, icon: String, theme: SpaceTheme, profiles: [Profile]?, profile: Profile.ID,
    done: @escaping (_ name: String, _ icon: String, _ theme: SpaceTheme, _ profile: Profile.ID) -> Void,
    cancel: @escaping () -> Void, opening: Opening? = nil, createProfile: ((String) -> Void)? = nil,
    confirm: String? = nil
  ) {
    self.title = title
    _name = State(initialValue: name)
    _icon = State(initialValue: icon)
    _theme = State(initialValue: theme)
    original = theme
    self.profiles = profiles
    _profile = State(initialValue: profile)
    self.done = done
    self.cancel = cancel
    self.opening = opening
    self.createProfile = createProfile
    self.confirm = confirm
  }
  @FocusState private var isNameFocused: Bool

  private var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    VStack(spacing: 8) {
      Illustration().padding(.top, 34)
        .task {
          isPickingTheme = opening == .theme
        }
      Text(title).font(.system(size: 17, weight: .semibold)).padding(.top, 8).padding(.bottom, 16)
      row(fill: Theme.field) {
        Button { isPickingIcon.toggle() } label: {
          Group {
            if icon.isEmpty {
              Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
            } else {
              SpaceIcon(icon: icon).frame(width: 18, height: 18)
            }
          }
          .foregroundStyle(Theme.secondaryText)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPickingIcon, arrowEdge: .bottom) { IconPicker(icon: $icon) }
        TextField("Space name...", text: $name)
          .textFieldStyle(.plain)
          .font(.system(size: 14))
          .focused($isNameFocused)
          .onSubmit { if isValid { done(name, icon, theme, profile) } }
      }
      if let profiles {
        row {
          Text("Profile").font(.system(size: 13, weight: .semibold)).padding(.leading, 8)
          Menu {
            Picker("", selection: $profile) {
              ForEach(profiles) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("New Profile…") { newProfile() }
          } label: {
            HStack(spacing: 4) {
              profiles.first { $0.id == profile }.map { Text($0.name) }
              Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Theme.fill, in: Capsule())
          }
          .menuStyle(.button)
          .buttonStyle(.plain)
          .menuIndicator(.hidden)
          .fixedSize()
          .onChange(of: profiles.map(\.id)) {
            guard awaitsNewProfile, let created = profiles.last else { return }
            awaitsNewProfile = false
            profile = created.id
          }
          Spacer()
          Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            .help("Spaces in a profile share its logins, history and favorites.")
        }
      }
      Button { isPickingTheme.toggle() } label: {
        row {
          Text("Choose a Theme").font(.system(size: 13, weight: .semibold)).padding(.leading, 8)
        }
      }
      .buttonStyle(.plain)
      .popover(isPresented: $isPickingTheme, arrowEdge: .trailing) {
        ThemePicker(theme: $theme, original: original, isEditing: profiles == nil, isPopover: true)
      }
      Spacer()
      // Not `.disabled`, which would dim the fill: the button only stops responding.
      Button { if isValid { done(name, icon, theme, profile) } } label: {
        Text(confirm ?? (profiles == nil ? "Save" : "Create Space")).font(.system(size: 13, weight: .semibold))
          .frame(maxWidth: .infinity, minHeight: 36)
          .foregroundStyle(isValid ? Theme.primaryText : Theme.disabledAccentText(theme))
          .background(
            isValid ? Theme.accent(theme) : Theme.disabledAccentFill(theme), in: RoundedRectangle(cornerRadius: 8))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.defaultAction)
      .allowsHitTesting(isValid)
      Button("Cancel", action: cancel)
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(Theme.secondaryText)
        .keyboardShortcut(.cancelAction)
        // Shot 31: Cancel 18 pt under the button, the dots 44 pt under Cancel.
        .padding(.top, 6)
        .padding(.bottom, 15)
    }
    .foregroundStyle(Theme.primaryText)
    // Shot 31: the rows and the button 14 pt in from the sidebar's edges.
    .padding(.horizontal, 14)
    // After it appears, so that it also takes the focus in a sheet, which installs it later.
    .task { isNameFocused = true }
    .preference(key: ThemePreview.self, value: theme)
    .preference(key: SpaceIconPreview.self, value: icon)
  }

  private func newProfile() {
    guard let createProfile, let window = NSApp.keyWindow else { return }
    presentModal(over: window) { dismiss in
      NewProfileDialog(
        create: {
          awaitsNewProfile = true
          createProfile($0)
        }, dismiss: dismiss)
    }
  }

  private func row(fill: Color = Theme.fill, @ViewBuilder content: () -> some View) -> some View {
    HStack(spacing: 8) { content() }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
      .background(fill, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
  }
}

// "Create a new Profile" from the space editor: the name alone, since the space being made will use it.
private struct NewProfileDialog: View {
  let create: (String) -> Void
  let dismiss: () -> Void
  @State private var name = ""

  var body: some View {
    ConfirmModal(
      confirm: "Create Profile", isValid: !name.trimmingCharacters(in: .whitespaces).isEmpty,
      onConfirm: {
        create(name.trimmingCharacters(in: .whitespaces))
        dismiss()
      },
      onCancel: dismiss
    ) {
      Text("Create a new Profile").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
      ModalField(placeholder: "Profile name", text: $name).padding(.top, 20)
    }
    .frame(width: 450)
  }
}

private struct Illustration: View {
  var body: some View {
    ZStack {
      ForEach([-14.0, 14.0, 0.0], id: \.self) { angle in
        RoundedRectangle(cornerRadius: 3)
          .fill(.white)
          .frame(width: 34, height: 40)
          .overlay(RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.5)).padding(4).padding(.bottom, 10))
          .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
          .rotationEffect(.degrees(angle), anchor: .bottom)
          .offset(x: angle)
      }
    }
    .frame(width: 66, height: 44)
  }
}

struct IconPicker: View {
  @Binding var icon: String
  @State private var isEmoji = true
  @State private var query = ""
  // The emoji whose skin tones are offered, after a right click or long press on it.
  @State private var toneBase: String?
  @FocusState private var isSearching: Bool

  private static let symbols = [
    "star.fill", "bookmark.fill", "heart.fill", "flag.fill", "bolt.fill", "triangle.fill", "asterisk", "bell.fill",
    "lightbulb.fill", "drop.fill", "square.grid.2x2.fill", "circle.grid.3x3.fill", "square.stack.3d.up.fill",
    "cylinder.split.1x2.fill", "tray.fill", "square.on.square", "folder.fill", "archivebox.fill", "calendar",
    "envelope.fill", "checkmark.square.fill", "doc.fill", "book.fill", "bubble.left.fill", "person.2.fill",
    "terminal.fill", "hammer.fill", "square.fill", "circle.fill", "moon.fill", "sun.max.fill", Space.primaryIcon, "leaf.fill",
    "cloud.fill", "pawprint.fill", "basket.fill", "gift.fill", "bed.double.fill", "airplane", "music.note",
    "paintpalette.fill", "video.fill", "chevron.left.forwardslash.chevron.right", "globe", "map.fill", "house.fill",
    "briefcase.fill", "gamecontroller.fill", "cart.fill",
  ]

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 8) {
        Picker("", selection: $isEmoji) {
          Text("Emoji").tag(true)
          Text("Icon").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // The trash can beside the tabs takes the icon away; with no icon there is none.
        if !icon.isEmpty {
          Button { icon = "" } label: {
            Image(systemName: "trash").font(.system(size: 12)).frame(width: 20, height: 20).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(Theme.secondaryText)
          .help("Remove Icon")
        }
      }
      if isEmoji {
        emojiGrid
      } else {
        grid(Self.symbols)
      }
    }
    .padding(12)
    .frame(width: 273)
  }

  // The emoji tab: a search field, the full emoji set and a bar that jumps to each category.
  private var emojiGrid: some View {
    ScrollViewReader { proxy in
      HStack(spacing: 5) {
        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($isSearching)
      }
      .padding(.horizontal, 6)
      .frame(height: 22)
      .background(Theme.fill, in: RoundedRectangle(cornerRadius: 5))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(isSearching ? 0.8 : 0), lineWidth: 2))
      .onAppear { isSearching = true }
      ScrollView {
        if query.isEmpty {
          LazyVStack(spacing: 4) {
            ForEach(Emoji.categories.indices, id: \.self) { index in
              grid(Emoji.categories[index].emoji).id(index)
            }
          }
        } else {
          grid(Emoji.all.filter { Emoji.name($0).contains(query.lowercased()) })
        }
      }
      .id(query.isEmpty)
      .frame(height: 155)
      .scrollIndicators(.never)
      // The skin tone picker: the emoji in each tone, over the grid.
      .overlay(alignment: .top) {
        if let base = toneBase {
          HStack(spacing: 4) {
            ForEach([base] + Emoji.skinTones.map { Emoji.toned(base, $0) }, id: \.self) { item in
              SpaceIcon(icon: item, emojiSize: 19)
                .frame(width: 27, height: 27)
                .background(icon == item ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture {
                  icon = item
                  toneBase = nil
                }
            }
          }
          .padding(6)
          .background(Theme.menu, in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
          .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
          .padding(.top, 4)
        }
      }
      .onChange(of: query) { toneBase = nil }
      Divider()
      HStack(spacing: 0) {
        ForEach(Emoji.categories.indices, id: \.self) { index in
          Button {
            query = ""
            proxy.scrollTo(index, anchor: .top)
          } label: {
            Image(systemName: Emoji.categories[index].icon).font(.system(size: 11))
              .frame(maxWidth: .infinity, minHeight: 18)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(Theme.secondaryText)
        }
      }
    }
  }

  private func grid(_ items: [String]) -> some View {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(27), spacing: 4), count: 8), spacing: 4) {
      ForEach(items, id: \.self) { item in
        SpaceIcon(icon: item, emojiSize: 19)
          .frame(width: 27, height: 27)
          .background(icon == item ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
          // A small dot marks an emoji that comes in skin tones, which a right click or a long press offers.
          .overlay(alignment: .bottomTrailing) {
            if Emoji.takesSkinTone(item) {
              Circle().fill(Theme.secondaryText).frame(width: 3, height: 3).padding(3)
            }
          }
          .contentShape(Rectangle())
          .onTapGesture {
            icon = item
            toneBase = nil
          }
          .onLongPressGesture(minimumDuration: 0.4) { if Emoji.takesSkinTone(item) { toneBase = item } }
          .modifier(SkinToneMenu(item: item, isOffered: Emoji.takesSkinTone(item)) { toneBase = item })
      }
    }
  }
}

struct SpaceIcon: View {
  let icon: String
  var emojiSize: CGFloat = 13
  // The symbol's point size; an emoji is drawn a point larger, as the two then span alike.
  var size: CGFloat = 12

  var body: some View {
    if icon.isEmpty {
      Circle().frame(width: 6, height: 6)
    } else if icon == Space.primaryIcon {
      Image(Space.primaryIcon).resizable().frame(width: size, height: size)
    } else if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
      Image(systemName: icon).font(.system(size: size))
    } else {
      Text(icon).font(.system(size: size == 12 ? emojiSize : size + 1))
    }
  }
}

// The icon picked in the space editor, which the footer's dot shows at once.
struct SpaceIconPreview: PreferenceKey {
  static let defaultValue: String? = nil

  static func reduce(value: inout String?, nextValue: () -> String?) {
    value = value ?? nextValue()
  }
}

// A right click on an emoji that comes in skin tones opens its tones.
private struct SkinToneMenu: ViewModifier {
  let item: String
  let isOffered: Bool
  let open: () -> Void

  func body(content: Content) -> some View {
    if isOffered {
      content.contextMenu { Button("Skin Tones") { open() } }
    } else {
      content
    }
  }
}
