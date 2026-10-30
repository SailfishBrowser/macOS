import AppKit
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

// The import dialog, which the onboarding steps share: its logo, title and words on the left, the step's choices on
// the right and its buttons at the bottom right, on navy. It keeps one size whatever the step.
struct ImportView: View {
  // Every step's size: the theme step's picker over the button row.
  static let size = CGSize(width: 720, height: 622)
  static let padding: CGFloat = 28
  @Bindable var store: StoreOf<ImportFeature>
  // After the first launch's intro all but the icon fade in, as the intro's icon lands on it.
  @State private var isShown: Bool
  @State private var browser: SourceBrowser?
  @State private var theme = SpaceTheme()
  @Shared(.blocksAds) private var blocksAds

  init(store: StoreOf<ImportFeature>) {
    self.store = store
    _isShown = State(initialValue: store.intro == nil)
  }

  var body: some View {
    ImportDialog(
      step: store.step, isShown: isShown, movesBack: { store.step == .browsers }, title: title, message: message,
      close: store.step == .browsers && !store.isOnboarding ? { store.send(.backTapped) } : nil
    ) {
      if store.step == .theme, let name = Binding($store.spaceName) {
        TextField("Space name", text: name).padding(.top, 12)
      }
    } content: {
      content
    } buttons: {
      buttons
    }
    .environment(\.colorScheme, .dark)
    .onAppear {
      store.send(.appeared)
      withAnimation(Motion.layout) { isShown = true }
    }
  }

  private var title: String {
    switch store.step {
    case .browsers: "Import from Another Browser"
    case .arc: "Import from \(store.arc!.browser.rawValue)"
    case .options: "Import from \(store.options!.browser.rawValue)"
    case .importing: "Import"
    case .finished: "Imported from \(store.summary!.browser.rawValue)"
    case .defaultBrowser: "Default Browser"
    case .theme: "Theme"
    case .adBlocker: "Ad Blocker"
    case .mediaFolders: "Media Folders"
    case .welcome: "Welcome to Sailfish, \(NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName())"
    }
  }

  private var message: String? {
    switch store.step {
    case .options: "Bookmarks become pinned tabs and folders of a new Space. Cookies keep you signed in to your sites."
    case .mediaFolders: "macOS asks to allow each folder."
    default: nil
    }
  }

  @ViewBuilder private var content: some View {
    switch store.step {
    case .browsers:
      VStack(spacing: 10) {
        if store.sources.isEmpty {
          Text("No other browser with data was found.").foregroundStyle(.secondary)
        }
        ForEach(store.sources) { source in
          BrowserChoice(browser: source.browser, isSelected: browser == source.browser) { browser = source.browser }
        }
      }
    case .arc:
      store.scope(state: \.arc, action: \.arc).map { ArcImportView(store: $0) }
    case .options:
      options
    case .importing:
      ProgressView().progressViewStyle(.linear).frame(width: 240)
    case .finished:
      finished
    case .defaultBrowser, .welcome:
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
    case .theme:
      ThemePicker(theme: $theme, original: SpaceTheme())
        .onChange(of: theme) { store.send(.themeChanged(theme)) }
    case .adBlocker:
      Toggle("Block ads and trackers with uBlock Origin", isOn: Binding($blocksAds))
        .toggleStyle(.switch)
        .onChange(of: blocksAds) { Engine.shared.adBlockingDidChange() }
    case .mediaFolders:
      MediaFolderList()
    }
  }

  @ViewBuilder private var buttons: some View {
    switch store.step {
    case .browsers:
      ImportDialogButton(title: "Maybe Later") { store.send(store.isOnboarding ? .nextTapped : .backTapped) }
        .keyboardShortcut(.cancelAction)
      ImportDialogButton(title: "Next", isPrimary: true) { browser.map { store.send(.browserTapped($0)) } }
        .keyboardShortcut(.defaultAction)
        .disabled(browser == nil)
    case .arc:
      if let arc = store.scope(state: \.arc, action: \.arc) {
        ImportDialogButton(title: "Cancel") { arc.send(.cancelTapped) }.keyboardShortcut(.cancelAction)
        ImportDialogButton(title: "Import", isPrimary: true) { arc.send(.importTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(arc.data == nil || !ArcImportFeature.Category.allCases.contains(where: arc.state.isIncluded))
      }
    case .options:
      ImportDialogButton(title: "Back") { store.send(.backTapped) }.keyboardShortcut(.cancelAction)
      ImportDialogButton(title: "Import", isPrimary: true) { store.send(.importTapped) }
        .keyboardShortcut(.defaultAction)
        .disabled(store.options?.canImport != true)
    case .importing:
      EmptyView()
    case .finished:
      ImportDialogButton(title: store.isOnboarding ? "Continue" : "Done", isPrimary: true) { store.send(.doneTapped) }
        .keyboardShortcut(.defaultAction)
    case .defaultBrowser:
      ImportDialogButton(title: "Not Now") { store.send(.nextTapped) }.keyboardShortcut(.cancelAction)
      ImportDialogButton(title: "Set as Default", isPrimary: true) { store.send(.makeDefaultTapped) }
        .keyboardShortcut(.defaultAction)
    case .theme:
      ImportDialogButton(title: "Not Now") { store.send(.nextTapped) }.keyboardShortcut(.cancelAction)
      ImportDialogButton(title: "Continue", isPrimary: true) { store.send(.themeChosen(theme)) }
        .keyboardShortcut(.defaultAction)
    case .adBlocker:
      ImportDialogButton(title: "Continue", isPrimary: true) { store.send(.nextTapped) }.keyboardShortcut(.defaultAction)
    case .mediaFolders:
      ImportDialogButton(title: "Continue", isPrimary: true) { store.send(.mediaFoldersTapped) }
        .keyboardShortcut(.defaultAction)
    case .welcome:
      ImportDialogButton(title: "Start Browsing", isPrimary: true) { store.send(.doneTapped) }
        .keyboardShortcut(.defaultAction)
    }
  }

  @ViewBuilder private var options: some View {
    if let options = Binding($store.options) {
      let current = options.wrappedValue
      VStack(alignment: .leading, spacing: 12) {
        if current.profiles.count > 1 {
          Picker("Profile", selection: Binding(get: { current.profile }, set: { store.send(.profileChosen($0)) })) {
            ForEach(current.profiles) { Text($0.name).tag($0) }
          }
        }
        Toggle("Bookmarks\(current.bookmarks.map { " (\(ImportFeature.tabCount($0)))" } ?? "")", isOn: options.includesBookmarks)
        if current.includesBookmarks {
          TextField("Space name", text: options.spaceName).padding(.leading, 20)
        }
        Toggle("History", isOn: options.includesHistory)
        if current.browser == .safari {
          HStack {
            Toggle("Passwords", isOn: options.includesPasswords).disabled(current.passwordsFile == nil)
            Button("Choose File…") { choosePasswordsFile() }
          }
          Text(
            current.passwordsFile?.lastPathComponent
              ?? "Other apps can't read Safari's passwords. In the Passwords app choose File > Export All Passwords to File, choose that file here, then delete it once imported."
          )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
          Toggle("Passwords", isOn: options.includesPasswords)
        }
        Toggle("Cookies", isOn: options.includesCookies)
        if let service = current.browser.safeStorage, current.includesPasswords || current.includesCookies {
          SafeStorageNote(service: service)
        }
        if let failure = current.failure {
          FailureView(failure: failure)
        } else if current.bookmarks == nil {
          ProgressView().controlSize(.small)
        }
      }
      .toggleStyle(.checkbox)
    }
  }

  private func choosePasswordsFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.message = "Choose the passwords file you exported from the Passwords app."
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let file = panel.url else { return }
    store.send(.passwordsFileChosen(file))
  }

  @ViewBuilder private var finished: some View {
    if let summary = store.summary {
      VStack(alignment: .leading, spacing: 8) {
        if summary.spaces > 0 {
          Text("\(summary.spaces) \(summary.spaces == 1 ? "space" : "spaces") with \(summary.tabs) tabs")
        }
        Text("\(summary.pages) pages of history")
        if let passwords = summary.passwords {
          Text("\(passwords) \(passwords == 1 ? "password" : "passwords")")
        }
        if let cookies = summary.cookies {
          Text("\(cookies) \(cookies == 1 ? "cookie" : "cookies")")
        }
        if let failure = summary.failure {
          FailureView(failure: failure)
        }
      }
    }
  }
}

// Each step's title and words crossfade in place and its choices slide, while the logo and the button row stay still,
// so the primary button never moves under the pointer.
private struct ImportDialog<Leading: View, Content: View, Buttons: View>: View {
  let step: ImportFeature.Step
  let isShown: Bool
  // Back, which returns only to the browsers.
  let movesBack: @MainActor () -> Bool
  let title: String
  let message: String?
  let close: (() -> Void)?
  @ViewBuilder let leading: Leading
  @ViewBuilder let content: Content
  @ViewBuilder let buttons: Buttons

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 32) {
        VStack(alignment: .leading, spacing: 14) {
          Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48).padding(.bottom, 26)
          ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 14) {
              Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
              if let message {
                Text(message).font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
              }
              leading
            }
            .id(step)
            .transition(.opacity)
          }
          .opacity(isShown ? 1 : 0)
        }
        .frame(width: 250, alignment: .leading)
        ZStack {
          content.frame(maxWidth: .infinity, maxHeight: .infinity).id(step).transition(StepSlide(movesBack: movesBack))
        }
        .opacity(isShown ? 1 : 0)
      }
      HStack(spacing: 8) {
        Spacer()
        buttons
      }
      .frame(height: 36)
      .padding(.top, 24)
      .transaction { $0.animation = nil }
      .opacity(isShown ? 1 : 0)
    }
    .animation(Motion.layout, value: step)
    .foregroundStyle(Color(hex: 0xD6D6D9))
    .padding(ImportView.padding)
    .frame(width: ImportView.size.width, height: ImportView.size.height)
    .background(Color(hex: 0x161C2F))
    .overlay(alignment: .topTrailing) {
      if let close {
        Button(action: close) {
          Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(20)
      }
    }
  }
}

// The step's choices move 24 pt as they fade: in from the trailing side and out toward the leading one, the other way
// on Back. The direction is read as the step changes, since the outgoing step last drew before it did.
private struct StepSlide: Transition {
  let movesBack: @MainActor () -> Bool

  func body(content: Content, phase: TransitionPhase) -> some View {
    content
      .offset(x: phase.value * (movesBack() ? 24 : -24))
      .opacity(phase.isIdentity ? 1 : 0)
  }
}

private struct ImportDialogButton: View {
  let title: String
  var isPrimary = false
  let action: () -> Void
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(action: action) {
      Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(isEnabled ? 1 : 0.4))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
          isPrimary ? Theme.accent.opacity(isEnabled ? 1 : 0.3) : Color(hex: 0x302F60),
          in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
    }
    .buttonStyle(.plain)
  }
}

// The browser choice: a radio, the browser's short name in capitals and its icon on a tinted end.
private struct BrowserChoice: View {
  let browser: SourceBrowser
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 0) {
        Circle().fill(.white).frame(width: 16, height: 16)
          .overlay(Circle().fill(Theme.accent).padding(4).opacity(isSelected ? 1 : 0))
          .padding(.horizontal, 14)
        Text(browser.rawValue.split(separator: " ").last!.uppercased())
          .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
        Spacer(minLength: 12)
        BrowserIcon(browser: browser).frame(width: 49, height: 48).background(.white.opacity(0.1))
      }
      .frame(width: 175, height: 48)
      .background(Color(hex: 0x262C45), in: RoundedRectangle(cornerRadius: 10))
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Theme.accent : .white.opacity(0.1)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// The folders the media folders step asks macOS for, as Finder shows them; the screenshots folder is often one of the
// others.
private struct MediaFolderList: View {
  var body: some View {
    let folders = MediaSources.allCases.compactMap(\.folder).map(\.standardizedFileURL)
      .reduce(into: [URL]()) { if !$0.contains($1) { $0.append($1) } }
    VStack(alignment: .leading, spacing: 10) {
      ForEach(folders, id: \.self) { folder in
        HStack(spacing: 10) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 24, height: 24)
          Text(FileManager.default.displayName(atPath: folder.path)).foregroundStyle(.white)
        }
      }
    }
  }
}

struct BrowserIcon: View {
  let browser: SourceBrowser

  var body: some View {
    let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID)
    // Zen's is bundled; another browser removed but for its data shows none.
    (browser == .zen ? Image("zen") : Image(nsImage: app.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()))
      .resizable()
      .frame(width: 24, height: 24)
  }
}

struct FailureView: View {
  let failure: ImportError

  var body: some View {
    switch failure {
    case .needsFullDiskAccess:
      VStack(alignment: .leading, spacing: 8) {
        Text("macOS keeps Safari's data from other apps. Allow Sailfish in System Settings > Privacy & Security > Full Disk Access, then quit and reopen Sailfish and import again.")
          .fixedSize(horizontal: false, vertical: true)
        Button("Open Full Disk Access Settings") {
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        }
      }
    case .keychainDenied:
      Text("macOS didn't let Sailfish use the browser's Safe Storage key, so its passwords and cookies weren't imported. Import again and allow it.")
        .fixedSize(horizontal: false, vertical: true)
    case .unreadable:
      Text("The data couldn't be read.")
    }
  }
}

// Why macOS asks for the keychain: the import reads the key the other browser encrypts with.
struct SafeStorageNote: View {
  let service: String

  var body: some View {
    Text("macOS will ask to let Sailfish use \u{201C}\(service)\u{201D} in your keychain. Enter your Mac password and click Always Allow. Your passwords are decrypted only on this Mac and saved encrypted with Sailfish's own key.")
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }
}
