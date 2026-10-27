import ComposableArchitecture
import SwiftUI

// The space menu, without Live Folders: on the space's title and footer dot in the sidebar, and on its card in the
// Library, which leaves out Manage Spaces….
struct SpaceMenu: View {
  let store: StoreOf<WindowFeature>
  let space: Space
  let changeIcon: () -> Void
  let editTheme: () -> Void
  let newFolder: () -> Void
  // Where the share picker points from, in the window's content view.
  let shareAnchor: () -> NSRect?

  var body: some View {
    Button("Change Space Icon…", action: changeIcon)
    Button("Rename Space…") { Self.rename(space, store) }
    Button("Edit Theme Color…", action: editTheme)
    SpaceProfileMenu(title: "Set Profile", store: store, space: space)
    Divider()
    Button("New Folder", action: newFolder)
    Divider()
    Button("Share Space…") { share() }
    // Export “…” into Folder: the space becomes a folder in the space picked. Every space is listed, this one
    // greyed out, so the submenu is never empty.
    Menu("Export “\(space.name)” into Folder") {
      ForEach(store.spaces.spaces) { item in
        Button(item.name) { store.send(.spaces(.spaceToFolder(space.id, into: item.id)), animation: Motion.row) }
          .disabled(item.id == space.id)
      }
    }
    if !store.isLibraryOpen {
      Divider()
      Button("Manage Spaces…") { store.send(.showLibrary(.spaces)) }
    }
    Divider()
    Button("Delete Space") { delete() }
      .disabled(store.spaces.spaces.count == 1)
  }

  // The Rename “Space” modal, as Spaces > Rename Space opens.
  static func rename(_ space: Space, _ store: StoreOf<WindowFeature>) {
    guard let window = NSApp.keyWindow else { return }
    presentModal(over: window) { dismiss in
      RenameSpaceDialog(
        space: space.name, save: { store.send(.spaces(.update(space.id, name: $0, icon: space.icon, theme: space.theme))) },
        dismiss: dismiss)
    }
  }

  // Asks before deleting a space with anything in it.
  private func delete() {
    guard let window = NSApp.keyWindow else { return }
    presentModal(over: window) { dismiss in
      DeleteSpaceDialog(name: space.name, delete: { store.send(.spaces(.delete(space.id))) }, dismiss: dismiss)
    }
  }

  // Shares the space's name and its pinned links.
  private func share() {
    guard let view = NSApp.keyWindow?.contentView, let anchor = shareAnchor() else { return }
    let links = space.tree().compactMap { if case let .tab(tab) = $0 { tab.url.absoluteString } else { nil } }
    NSSharingServicePicker(items: [([space.name] + links).joined(separator: "\n")])
      .show(relativeTo: anchor, of: view, preferredEdge: .maxX)
  }
}

struct SpaceProfileMenu: View {
  let title: String
  let store: StoreOf<WindowFeature>
  let space: Space

  var body: some View {
    Menu(title) {
      // Sorted by character code, capitals first: "Work" before "test".
      ForEach(store.spaces.profiles.sorted { $0.name < $1.name }) { profile in
        Toggle(profile.name, isOn: Binding { profile.id == space.profileID } set: { _ in switchProfile(to: profile) })
      }
      Divider()
      Button("New Profile…") { newProfile() }
    }
    .disabled(store.isIncognito)
  }

  // Moving a space to another profile reloads its tabs there, signed out, so it asks first.
  private func switchProfile(to profile: Profile) {
    guard profile.id != space.profileID, let window = NSApp.keyWindow else { return }
    presentModal(over: window) { dismiss in
      SwitchProfileDialog(
        space: space.name, profile: profile.name, switchProfile: { store.send(.spaces(.setProfile(space.id, profile.id))) },
        dismiss: dismiss)
    }
  }

  private func newProfile() {
    guard let window = NSApp.keyWindow else { return }
    let spaces = Array(store.spaces.spaces)
    presentModal(over: window) { dismiss in
      CreateProfileDialog(spaces: spaces, create: { store.send(.createProfile(name: $0, spaces: $1)) }, dismiss: dismiss)
    }
  }
}
