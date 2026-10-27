import AppKit
import SwiftUI

private final class ModalPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

// Shows a dark modal centered over `window`, dismissed by the closure its content gets.
@MainActor
func presentModal<V: View>(over window: NSWindow, content: (_ dismiss: @escaping () -> Void) -> V) {
  let panel = ModalPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
  panel.isOpaque = false
  panel.backgroundColor = .clear
  panel.hasShadow = true
  panel.isReleasedWhenClosed = false
  let dismiss = { [weak window, weak panel] in
    guard let panel else { return }
    window?.removeChildWindow(panel)
    panel.close()
    window?.makeKeyAndOrderFront(nil)
  }
  let host = NSHostingController(rootView: content(dismiss).environment(\.colorScheme, .dark))
  host.sizingOptions = .preferredContentSize
  panel.contentViewController = host
  let size = host.view.fittingSize
  panel.setFrame(
    NSRect(x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2, width: size.width, height: size.height),
    display: true)
  window.addChildWindow(panel, ordered: .above)
  panel.makeKey()
}

// The modal: a navy rounded panel with "Cancel ESC" and an accent confirm button with a ↩ keycap.
struct ConfirmModal<Content: View>: View {
  let confirm: String
  var cancel = "Cancel"
  // The accent, or red for a destructive action.
  var confirmFill = Theme.accent
  var confirmKeycap = Color.white.opacity(0.2)
  let isValid: Bool
  let onConfirm: () -> Void
  let onCancel: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content
      HStack(spacing: 8) {
        Spacer()
        button(cancel, key: "ESC", fill: Color(hex: 0x302F60), keycap: Color(hex: 0x494772), action: onCancel)
          .keyboardShortcut(.cancelAction)
        button(confirm, key: "↩", fill: confirmFill, keycap: confirmKeycap, action: onConfirm)
          .keyboardShortcut(.defaultAction)
          .disabled(!isValid)
          .opacity(isValid ? 1 : 0.4)
      }
      .padding(.top, 30)
    }
    .foregroundStyle(Color(hex: 0xD6D6D9))
    .padding(36)
    .background(Color(hex: 0x161C2F), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1)))
  }

  private func button(_ title: String, key: String, fill: Color, keycap: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        // Shots 40 and 78: 13 pt regular ("Cancel" 41 pt, "Delete" 39 pt) on a 38 pt button.
        Text(title).font(.system(size: 13))
        Text(key).font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).frame(height: 20)
          .background(keycap, in: RoundedRectangle(cornerRadius: 4))
      }
      .foregroundStyle(.white)
      .padding(.leading, 14)
      .padding(.trailing, 8)
      .frame(height: 38)
      .background(fill, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
    }
    .buttonStyle(.plain)
  }
}

struct ModalField: View {
  let placeholder: String
  @Binding var text: String
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField(placeholder, text: $text)
      .textFieldStyle(.plain)
      .font(.system(size: 14))
      .focused($isFocused)
      .padding(.horizontal, 10)
      .frame(height: 40)
      .background(Color(hex: 0x262B3D), in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
      .onAppear {
        isFocused = true
        // The current text is preselected, so typing replaces it.
        DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil) }
      }
  }
}

struct RenameProfileDialog: View {
  @State var name: String
  let save: (String) -> Void
  let dismiss: () -> Void

  var body: some View {
    ConfirmModal(
      confirm: "Save", isValid: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      onConfirm: {
        save(name)
        dismiss()
      },
      onCancel: dismiss
    ) {
      Text("Rename your Profile").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
      Text("This won't affect the names of any of the Spaces associated with this Profile.")
        .font(.system(size: 13)).padding(.top, 10)
      ModalField(placeholder: "", text: $name).padding(.top, 20)
    }
    .frame(width: 496)
  }
}

// The delete confirmation: the profile's name typed back, Default and used profiles excepted.
struct DeleteProfileDialog: View {
  let name: String
  let delete: () -> Void
  let dismiss: () -> Void
  @State private var typed = ""

  var body: some View {
    ConfirmModal(
      confirm: "Delete", confirmFill: Color(hex: 0xE8432A), confirmKeycap: Color(hex: 0xF07A66), isValid: typed == name,
      onConfirm: {
        dismiss()
        delete()
      },
      onCancel: dismiss
    ) {
      Text("Delete your “\(name)” Profile?").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
      Text("This permanently removes its history, logins, cookies and extensions from this computer. Type the Profile's name to confirm.")
        .font(.system(size: 13)).padding(.top, 10)
      ModalField(placeholder: name, text: $typed).padding(.top, 20)
    }
    .frame(width: 496)
  }
}

// The Spaces > Rename Space dialog: the name preselected, Cancel and Rename.
struct RenameSpaceDialog: View {
  let space: String
  let save: (String) -> Void
  let dismiss: () -> Void
  @State private var name: String

  init(space: String, save: @escaping (String) -> Void, dismiss: @escaping () -> Void) {
    self.space = space
    self.save = save
    self.dismiss = dismiss
    _name = State(initialValue: space)
  }

  var body: some View {
    ConfirmModal(
      confirm: "Rename", isValid: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      onConfirm: {
        save(name.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
      },
      onCancel: dismiss
    ) {
      Text("Rename “\(space)”").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
      ModalField(placeholder: "", text: $name).padding(.top, 20)
    }
    .frame(width: 450)
  }
}

// The Spaces > Change Profile dialog: the space's profile in a pop-up, with the data that changes with it.
struct ChangeProfileDialog: View {
  let space: String
  let profiles: [Profile]
  let current: Profile.ID
  let change: (Profile.ID) -> Void
  let dismiss: () -> Void
  @State private var selection: Profile.ID

  init(space: String, profiles: [Profile], current: Profile.ID, change: @escaping (Profile.ID) -> Void, dismiss: @escaping () -> Void) {
    self.space = space
    self.profiles = profiles
    self.current = current
    self.change = change
    self.dismiss = dismiss
    _selection = State(initialValue: current)
  }

  var body: some View {
    ConfirmModal(
      confirm: "Change Profile", isValid: true,
      onConfirm: {
        if selection != current { change(selection) }
        dismiss()
      },
      onCancel: dismiss
    ) {
      Image(systemName: "person.crop.circle").font(.system(size: 40)).foregroundStyle(Color(hex: 0xB9B8E8))
        .frame(width: 60, height: 60)
        .background(Color(hex: 0x3A3F6B), in: RoundedRectangle(cornerRadius: 14))
        .padding(.bottom, 16)
      (Text("Change ") + Text("\(space)'s").bold() + Text(" Profile"))
        .font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
      Text(
        "Each Profile has different browser data, so you might get logged out of some websites, see different "
          + "Favorites up top, or need to re-install extensions."
      )
      .font(.system(size: 14)).padding(.top, 10)
      HStack(spacing: 8) {
        Text("\(space)'s Profile").font(.system(size: 13, weight: .semibold))
        Picker("", selection: $selection) {
          ForEach(profiles) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .fixedSize()
      }
      .padding(.top, 14)
    }
    .frame(width: 450)
  }
}

// The Tabs > New Folder… dialog.
struct NewFolderDialog: View {
  let create: (String) -> Void
  let dismiss: () -> Void
  @State private var name = ""

  var body: some View {
    ConfirmModal(
      confirm: "Create", isValid: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      onConfirm: {
        create(name.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
      },
      onCancel: dismiss
    ) {
      Text("New Folder…").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
      ModalField(placeholder: "What are you organizing?", text: $name).padding(.top, 20)
    }
    .frame(width: 450)
  }
}

// "Create a new Profile": a name, then the spaces that move to the new profile.
struct CreateProfileDialog: View {
  let spaces: [Space]
  let create: (_ name: String, _ spaces: Set<Space.ID>) -> Void
  let dismiss: () -> Void
  @State private var name = ""
  @State private var isChoosing = false
  @State private var chosen: Set<Space.ID> = []

  var body: some View {
    if isChoosing {
      ConfirmModal(
        confirm: "Create Profile", cancel: "Back", isValid: !chosen.isEmpty,
        onConfirm: {
          create(name, chosen)
          dismiss()
        },
        onCancel: { isChoosing = false }
      ) {
        header("Which Spaces should use this Profile?")
        Text(
          "These Spaces will start fresh in your brand new Profile — so you'll have to log back in to websites, "
            + "re-save your passwords, add extensions, etc. You can always switch back to your previous Profile "
            + "though if you forgot something!"
        )
        .font(.system(size: 14)).padding(.top, 12)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .top, spacing: 12) {
            ForEach(spaces) { space in
              let isChosen = chosen.contains(space.id)
              VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 10).fill(LinearGradient(theme: space.theme)).frame(width: 50, height: 76)
                  .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                  .font(.system(size: 16))
                  .foregroundStyle(isChosen ? .white : .secondary, isChosen ? .green : .clear)
                Text(space.name).font(.system(size: 11)).lineLimit(1).frame(width: 60)
              }
              .contentShape(Rectangle())
              .onTapGesture { chosen.formSymmetricDifference([space.id]) }
            }
          }
        }
        .padding(.top, 20)
      }
      .frame(width: 450)
    } else {
      ConfirmModal(
        confirm: "Next", isValid: !name.trimmingCharacters(in: .whitespaces).isEmpty,
        onConfirm: { isChoosing = true }, onCancel: dismiss
      ) {
        header("Create a new Profile")
        Text(
          "Profiles make your Spaces truly separate — with their own history, saved passwords, extensions, "
            + "and other browsing data. No more flipping between work and personal accounts!"
        )
        .font(.system(size: 14)).padding(.top, 12)
        Text("What do you want to call this Profile?").font(.system(size: 14, weight: .medium)).padding(.top, 24)
        ModalField(placeholder: "Personal", text: $name).padding(.top, 12)
        (Text(Image(systemName: "arrow.triangle.2.circlepath")) + Text(" Profiles are ")
          + Text("not synced").bold() + Text(" between computers."))
          .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
      }
      .frame(width: 450)
    }
  }

  private func header(_ title: String) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Image(systemName: "face.smiling").font(.system(size: 40)).foregroundStyle(Color(hex: 0xB9B8E8))
        .frame(width: 60, height: 60)
        .background(Color(hex: 0x3A3F6B), in: Circle())
        .overlay(alignment: .bottomTrailing) {
          Image(systemName: "plus.circle.fill").font(.system(size: 16)).foregroundStyle(.white, .green)
        }
      Text(title).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
    }
  }
}

// The "Delete your “…” Space?" dialog.
// "Are you sure you'd like to Clear Archive?".
struct ClearArchiveDialog: View {
  let clear: () -> Void
  let dismiss: () -> Void

  var body: some View {
    ConfirmModal(
      confirm: "Clear Archive", confirmFill: Color(hex: 0xE8432A), confirmKeycap: Color(hex: 0xF07A66), isValid: true,
      onConfirm: {
        dismiss()
        clear()
      },
      onCancel: dismiss
    ) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).padding(.bottom, 14)
      Text("Are you sure you'd like to Clear Archive?").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
      Text("Every archived tab will be deleted.").font(.system(size: 14)).padding(.top, 14)
    }
    .frame(width: 450)
  }
}

struct DeleteSpaceDialog: View {
  let name: String
  let delete: () -> Void
  let dismiss: () -> Void

  var body: some View {
    ConfirmModal(
      confirm: "Delete", confirmFill: Color(hex: 0xE8432A), confirmKeycap: Color(hex: 0xF07A66), isValid: true,
      onConfirm: {
        dismiss()
        delete()
      },
      onCancel: dismiss
    ) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56).padding(.bottom, 14)
      // Shot 40: 17 pt bold, 256 pt for “Clone Ref”.
      Text("Delete your “\(name)” Space?").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
      Text("This will archive all the tabs and folders inside it.").font(.system(size: 14)).padding(.top, 14)
    }
    .frame(width: 450)
  }
}
