import AppKit
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

// The import dialog, which the onboarding steps share: its logo, title and words on the left, the step's choices on
// the right and its buttons at the bottom right, on navy.
struct ImportView: View {
  @Bindable var store: StoreOf<ImportFeature>
  @State private var browser: SourceBrowser?
  @State private var theme = SpaceTheme()
  @Shared(.blocksAds) private var blocksAds

  var body: some View {
    Group {
      switch store.step {
      case .browsers: browsers
      case .arc: store.scope(state: \.arc, action: \.arc).map { ArcImportView(store: $0) }
      case .options: options
      case .importing:
        ImportDialog(title: "Importing…", message: "Bringing everything over.") {
          ProgressView()
        } buttons: {}
      case .finished: finished
      case .defaultBrowser:
        ImportDialog(
          title: "Go steady with Sailfish?",
          message: "Make Sailfish your default browser so links open here. We'll treat your links nicely – you won't regret it, we promise!"
        ) {
          Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
        } buttons: {
          ImportDialogButton(title: "Not Now") { store.send(.nextTapped) }.keyboardShortcut(.cancelAction)
          ImportDialogButton(title: "Set as Default", isPrimary: true) { store.send(.makeDefaultTapped) }
            .keyboardShortcut(.defaultAction)
        }
      case .theme:
        ImportDialog(
          title: "Add some flair with a theme.",
          message: "Pick a color, any color – add your favorite shade to your new home on the internet."
        ) {
          VStack(alignment: .leading, spacing: 12) {
            if let name = Binding($store.spaceName) {
              TextField("Space name", text: name)
            }
            ThemePicker(theme: $theme, original: SpaceTheme())
          }
        } buttons: {
          ImportDialogButton(title: "Not Now") { store.send(.nextTapped) }.keyboardShortcut(.cancelAction)
          ImportDialogButton(title: "Continue", isPrimary: true) { store.send(.themeChosen(theme)) }
            .keyboardShortcut(.defaultAction)
        }
      case .adBlocker:
        ImportDialog(
          title: "No more ads or trackers.",
          message: "We include an ad blocker so you don't need to worry about invasive trackers or intrusive pop-ups."
        ) {
          Toggle("Block ads and trackers with uBlock Origin", isOn: Binding($blocksAds))
            .toggleStyle(.switch)
            .onChange(of: blocksAds) { Engine.shared.adBlockingDidChange() }
        } buttons: {
          ImportDialogButton(title: "Continue", isPrimary: true) { store.send(.nextTapped) }.keyboardShortcut(.defaultAction)
        }
      case .mediaFolders:
        ImportDialog(
          title: "Your media, all in one place.",
          message: "The Library shows the images and videos in your Documents, Desktop, Downloads and screenshots folders. macOS will ask you to allow each one."
        ) {
          Image(systemName: "photo.on.rectangle").font(.system(size: 96, weight: .light))
        } buttons: {
          ImportDialogButton(title: "Continue", isPrimary: true) { store.send(.mediaFoldersTapped) }
            .keyboardShortcut(.defaultAction)
        }
      case .welcome:
        ImportDialog(
          title: "Welcome to Sailfish, \(NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName())",
          message: "And with that, you're now ready to experience your upgraded internet."
        ) {
          Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
        } buttons: {
          ImportDialogButton(title: "Start Browsing", isPrimary: true) { store.send(.doneTapped) }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .environment(\.colorScheme, .dark)
    .onAppear { store.send(.appeared) }
  }

  private var browsers: some View {
    ImportDialog(
      title: store.isOnboarding ? "Get us up to speed." : "Import from your old browser",
      message: store.isOnboarding
        ? "It's a bold new internet. Hit the ground running and bring your spaces, bookmarks and history with you."
        : "Import everything you need from your old browser to hit the ground running with Sailfish.",
      close: store.isOnboarding ? nil : { store.send(.backTapped) }
    ) {
      VStack(spacing: 10) {
        if store.sources.isEmpty {
          Text("No other browser with data was found.").foregroundStyle(.secondary)
        }
        ForEach(store.sources) { source in
          BrowserChoice(browser: source.browser, isSelected: browser == source.browser) { browser = source.browser }
        }
      }
    } buttons: {
      ImportDialogButton(title: "Maybe Later") { store.send(store.isOnboarding ? .nextTapped : .backTapped) }
        .keyboardShortcut(.cancelAction)
      ImportDialogButton(title: "Next", isPrimary: true) { browser.map { store.send(.browserTapped($0)) } }
        .keyboardShortcut(.defaultAction)
        .disabled(browser == nil)
    }
  }

  @ViewBuilder private var options: some View {
    if let options = Binding($store.options) {
      let current = options.wrappedValue
      ImportDialog(
        title: "Import from \(current.browser.rawValue)",
        message: "Bookmarks become pinned tabs and folders of a new Space. Cookies keep you signed in to your sites."
      ) {
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
      } buttons: {
        ImportDialogButton(title: "Back") { store.send(.backTapped) }.keyboardShortcut(.cancelAction)
        ImportDialogButton(title: "Import", isPrimary: true) { store.send(.importTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(!current.canImport)
      }
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
      ImportDialog(title: "Imported from \(summary.browser.rawValue)", message: "Everything's in its place.") {
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
      } buttons: {
        ImportDialogButton(title: store.isOnboarding ? "Continue" : "Done", isPrimary: true) { store.send(.doneTapped) }
          .keyboardShortcut(.defaultAction)
      }
    }
  }
}

private struct ImportDialog<Content: View, Buttons: View>: View {
  let title: String
  let message: String
  var close: (() -> Void)? = nil
  @ViewBuilder let content: Content
  @ViewBuilder let buttons: Buttons

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 32) {
        VStack(alignment: .leading, spacing: 14) {
          Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48).padding(.bottom, 26)
          Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
          Text(message).font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 250, alignment: .leading)
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      HStack(spacing: 8) {
        Spacer()
        buttons
      }
      .padding(.top, 24)
    }
    .foregroundStyle(Color(hex: 0xD6D6D9))
    .padding(28)
    .frame(minWidth: 580, minHeight: 454)
    .fixedSize()
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
