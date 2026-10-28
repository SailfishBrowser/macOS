import AppKit
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

// What an Arc folder or a Zen profile holds, by kind, each kind with a checkbox, as the import sheets of other
// browsers list theirs.
struct ArcImportView: View {
  let store: StoreOf<ArcImportFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Import from \(store.browser.rawValue)").font(.headline)
      if store.browser == .arc {
        HStack {
          Text((store.folder.path as NSString).abbreviatingWithTildeInPath)
            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
          Spacer()
          Button("Choose Folder…") { chooseFolder() }
        }
      } else if store.profiles.count > 1 {
        Picker("Profile", selection: Binding(get: { store.folder }, set: { store.send(.folderChosen($0)) })) {
          ForEach(store.profiles) { Text($0.name).tag($0.folder) }
        }
      }
      if let data = store.data {
        contents(data)
      } else if let failure = store.failure {
        Text(
          failure == .notFound
            ? store.browser == .arc ? "No Arc data in this folder." : "No Zen 1.18 or later data in this profile."
            : "The \(store.browser.rawValue) data couldn't be read.")
      } else {
        ProgressView().controlSize(.small)
      }
      HStack {
        Spacer()
        Button("Cancel") { store.send(.cancelTapped) }.keyboardShortcut(.cancelAction)
        Button("Import") { store.send(.importTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(store.data == nil || !ArcImportFeature.Category.allCases.contains(where: store.state.isIncluded))
      }
    }
    .padding(16)
    .frame(width: 440)
    .onAppear { store.send(.appeared) }
  }

  private func contents(_ data: ArcData) -> some View {
    let pinned = data.spaces.flatMap(\.pinned)
    let profiles = Set(data.spaces.map(\.profile)).count
    let isArc = store.browser == .arc
    return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
      row(.spaces, "Spaces", profiles > 1 ? "\(data.spaces.count) in \(profiles) profiles" : "\(data.spaces.count)")
      row(.pinnedTabs, "Pinned Tabs", count(pinned), indented: true)
      row(.todayTabs, isArc ? "Today Tabs" : "Open Tabs", "\(data.spaces.map(\.today.count).reduce(0, +))", indented: true)
      row(.favorites, isArc ? "Favorites" : "Essentials", "\(data.favorites.map(\.tabs.count).reduce(0, +))")
      if isArc {
        row(.shortcuts, "Shortcuts", "\(store.shortcuts.bindings.count)")
      } else {
        row(.bookmarks, "Bookmarks", count(data.bookmarks?.pinned ?? []))
      }
      if !store.shortcuts.skipped.isEmpty {
        GridRow {
          Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
          Text("Not imported: " + store.shortcuts.skipped.joined(separator: ", "))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .gridCellColumns(2)
        }
      }
      if isArc {
        row(.archive, "Archived Tabs", archiveCount(data.archive.count))
      }
      row(.history, "History", "")
      if isArc {
        row(.passwords, "Passwords", "")
      } else {
        GridRow {
          toggle(.passwords, "Passwords")
          Spacer()
          Button("Choose File…") { choosePasswordsFile() }
        }
        GridRow {
          Text(
            store.passwordsFile?.lastPathComponent
              ?? "Other apps can't read Zen's passwords. In Zen open about:logins, choose Export Passwords… from its menu, choose that file here, then delete it once imported."
          )
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).gridCellColumns(3)
        }
      }
      row(.cookies, "Cookies", "")
      if isArc, store.state.isIncluded(.passwords) || store.state.isIncluded(.cookies) {
        GridRow {
          SafeStorageNote(service: SourceBrowser.arc.safeStorage!).gridCellColumns(3)
        }
      }
    }
  }

  // As many as the archive has room for, the newest.
  private func archiveCount(_ count: Int) -> String {
    let room = ArcImportFeature.archiveRoom
    return switch room {
    case count...: "\(count)"
    case 0: "0 of \(count.formatted())"
    default: "Newest \(room.formatted()) of \(count.formatted())"
    }
  }

  private func row(_ category: ArcImportFeature.Category, _ title: String, _ count: String, indented: Bool = false) -> some View {
    GridRow {
      toggle(category, title).padding(.leading, indented ? 20 : 0)
      Spacer()
      Text(count).foregroundStyle(.secondary).monospacedDigit().gridColumnAlignment(.trailing)
    }
  }

  private func toggle(_ category: ArcImportFeature.Category, _ title: String) -> some View {
    Toggle(title, isOn: Binding(get: { store.state.isIncluded(category) }, set: { store.send(.toggled(category, $0)) }))
      .toggleStyle(.checkbox)
      .disabled(!store.state.isAvailable(category))
  }

  // The tabs, and the folders among them.
  private func count(_ rows: [ArcData.Row]) -> String {
    func tally(_ rows: [ArcData.Row]) -> (tabs: Int, folders: Int) {
      rows.reduce((0, 0)) { total, row in
        switch row {
        case .tab: return (total.tabs + 1, total.folders)
        case let .folder(_, rows):
          let inner = tally(rows)
          return (total.tabs + inner.tabs, total.folders + 1 + inner.folders)
        }
      }
    }
    let total = tally(rows)
    return switch total.folders {
    case 0: "\(total.tabs)"
    case 1: "\(total.tabs) tabs, 1 folder"
    default: "\(total.tabs) tabs, \(total.folders) folders"
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.directoryURL = store.folder
    panel.message = "Choose Arc's data folder, which holds StorableSidebar.json."
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    store.send(.folderChosen(folder))
  }

  private func choosePasswordsFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.message = "Choose the passwords file you exported from Zen."
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let file = panel.url else { return }
    store.send(.passwordsFileChosen(file))
  }
}
