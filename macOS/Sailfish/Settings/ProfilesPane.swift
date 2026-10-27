import AppKit
import ComposableArchitecture
@preconcurrency import EngineCore
import SwiftUI

struct ProfilesPane: View {
  let store: StoreOf<AppFeature>
  let openPage: (URL, Profile.ID) -> Void
  @Shared(.profiles) private var profiles
  @State private var selection: Profile.ID?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Profiles keep your history, logins, cookies and extensions apart. Each Space uses one profile, and a profile can serve several Spaces.")
        .font(.system(size: 13))
        .frame(width: 546, alignment: .leading)
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 0) {
          Text("Your Profiles").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).frame(height: 28)
          Divider()
          // The rows: 40 pt with separators and a subtle highlight for the selected one.
          ScrollView {
            VStack(spacing: 0) {
              ForEach(profiles) { profile in
                let count = store.state.spaceCount(profile.id)
                HStack {
                  Text(profile.name).font(.system(size: 13)).lineLimit(1)
                  Spacer()
                  Text(count == 0 ? "Not used" : count == 1 ? "1 Space" : "\(count) Spaces")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 40)
                .background(selection == profile.id ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { selection = profile.id }
                .contextMenu {
                  Button("Rename Profile…") { rename(profile) }
                  Button("Delete Profile…") { confirmDelete(profile) }.disabled(!store.state.canDeleteProfile(profile.id))
                  Divider()
                  Button("Delete unused Profiles") { store.send(.deleteUnusedProfiles) }.disabled(store.state.unusedProfiles.isEmpty)
                }
                Divider().padding(.horizontal, 8)
              }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
          }
          Divider()
          HStack(spacing: 0) {
            footerButton("plus", help: "New Profile") {
              // Shown over the browser window.
              let window = NSApp.orderedWindows.first { $0.windowController is WindowController } ?? NSApp.keyWindow!
              window.makeKeyAndOrderFront(nil)
              let spaces = store.windows.filter { !$0.isIncognito }.flatMap(\.spaces.spaces)
              presentModal(over: window) { dismiss in
                CreateProfileDialog(spaces: spaces, create: { store.send(.createProfile(name: $0, spaces: $1)) }, dismiss: dismiss)
              }
            }
            Divider().frame(height: 16)
            footerButton("minus", help: "Delete Profile") { selection.flatMap { profiles[id: $0] }.map(confirmDelete) }
              .disabled(!(selection.map(store.state.canDeleteProfile) ?? false))
            Divider().frame(height: 16)
            footerButton("pencil.line", help: "Rename Profile") { selection.flatMap { profiles[id: $0] }.map(rename) }
              .disabled(selection == nil)
          }
          .padding(4)
        }
        .frame(width: 196, height: 420)
        .settingsCard()
        if let selection {
          ProfileSettings(
            profile: selection, openPage: { openPage($0, selection) },
            setArchiveAfter: { store.send(.setArchiveAfter(selection, $0)) }
          )
          .id(selection)
        }
      }
    }
    .padding(.vertical, 20)
    .padding(.horizontal, 64)
    .onAppear { selection = selection ?? profiles.first?.id }
    .onChange(of: profiles.count) { selection = profiles.last?.id }
  }

  private func footerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 24) }
      .buttonStyle(.borderless)
      .help(help)
  }

  private func rename(_ profile: Profile) {
    presentModal(over: NSApp.keyWindow!) { dismiss in
      RenameProfileDialog(name: profile.name, save: { store.send(.renameProfile(profile.id, name: $0)) }, dismiss: dismiss)
    }
  }

  private func confirmDelete(_ profile: Profile) {
    presentModal(over: NSApp.keyWindow!) { dismiss in
      DeleteProfileDialog(name: profile.name, delete: { store.send(.deleteProfile(profile.id)) }, dismiss: dismiss)
    }
  }
}

// The profile's settings that the engine keeps in its preferences.
private struct ProfileSettings: View {
  let profile: Profile.ID
  let openPage: (URL) -> Void
  let setArchiveAfter: (TimeInterval?) -> Void
  @State private var context: ECBrowserContext?
  @State private var suggest = false
  @State private var downloads: URL?
  @Shared(.profiles) private var profiles

  var body: some View {
    VStack(spacing: 10) {
      if let context, let downloads {
        VStack(spacing: 0) {
          row("Manage search") {
            Button("Search Settings…") { openPage(URL(string: "chrome://settings/searchEngines")!) }
          }
          Divider().padding(.horizontal, 10)
          row("Include search engine suggestions") {
            Toggle("", isOn: Binding { suggest } set: { suggest = $0; context.searchSuggestEnabled = $0 })
              .toggleStyle(.switch).controlSize(.mini).labelsHidden()
          }
        }
        .settingsCard()
        row("Archive tabs after") {
          Picker("", selection: Binding { profiles[id: profile]!.archiveAfter } set: { setArchiveAfter($0) }) {
            ForEach([12.0, 24, 7 * 24, 30 * 24], id: \.self) { hours in
              Text(hours == 12 ? "12 hours (default)" : hours < 48 ? "\(Int(hours)) hours" : "\(Int(hours / 24)) days")
                .tag(Optional(hours * 3600))
            }
            Text("Never").tag(TimeInterval?.none)
          }
          .labelsHidden()
          .frame(width: 180)
        }
        .settingsCard()
        row("Download location") {
          Menu {
            Button("Other…") { chooseDownloads(context) }
          } label: {
            Label(downloads.lastPathComponent, systemImage: "folder.fill")
          }
          .frame(width: 180)
        }
        .settingsCard()
        Text("Your Data and Settings").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
        VStack(spacing: 0) {
          ForEach(Self.pages, id: \.0) { title, symbol, color, page in
            HStack(spacing: 10) {
              Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(color, in: RoundedRectangle(cornerRadius: 5))
              Text(title).font(.system(size: 13))
              Spacer()
              Image(systemName: "arrow.right").foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .onTapGesture { openPage(URL(string: "chrome://" + page)!) }
          }
        }
        .settingsCard()
      }
    }
    .frame(width: 340, alignment: .top)
    .task {
      let context = await Engine.shared.context(profile)
      suggest = context.searchSuggestEnabled
      downloads = context.downloadDirectory
      self.context = context
    }
  }

  // Chrome's settings pages for the profile, opened in a tab.
  private static let pages: [(String, String, Color, String)] = [
    ("Privacy and Security", "lock.fill", .blue, "settings/privacy"),
    ("Passwords", "key.fill", .green, "password-manager/passwords"),
    ("Credit Cards", "creditcard.fill", .yellow, "settings/payments"),
    ("Notifications", "bell.fill", .orange, "settings/content/notifications"),
    ("Clear Browsing Data", "trash.fill", .red, "settings/clearBrowserData"),
  ]

  private func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
    HStack {
      Text(title).font(.system(size: 13))
      Spacer()
      control()
    }
    .padding(.horizontal, 10)
    .frame(height: 40)
  }

  private func chooseDownloads(_ context: ECBrowserContext) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.directoryURL = downloads
    guard panel.runModal() == .OK, let url = panel.url else { return }
    context.downloadDirectory = url
    downloads = url
  }
}
