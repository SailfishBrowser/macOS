import AppKit
@preconcurrency import EngineCore
import UniformTypeIdentifiers

extension Engine {
  // Chrome's permission keys: the site controls title, the prompt wording and an icon.
  static let permissions: [String: (title: String, ask: String, symbol: String)] = [
    "ambient_login": ("Automatic Sign-In", "Sign you in automatically", "person.badge.key.fill"),
    "ar_session": ("Augmented Reality", "Create a 3D map of your surroundings", "arkit"),
    "camera_pan_tilt_zoom": ("Camera Movement", "Move your camera", "video.fill"),
    "camera_stream": ("Camera", "Use your camera", "video.fill"),
    "captured_surface_control": ("Shared Tab Control", "Scroll and zoom shared tabs", "rectangle.on.rectangle"),
    "clipboard": ("Clipboard", "See text and images you copy", "doc.on.clipboard.fill"),
    "disk_quota": ("Storage", "Store more data on this device", "internaldrive.fill"),
    "file_system": ("File Editing", "Edit files on this device", "folder.fill"),
    "geolocation": ("Location", "Access your location", "location.fill"),
    "hand_tracking": ("Hand Tracking", "Track your hands", "hand.raised.fill"),
    "identity_provider": ("Identity Services", "Sign you in with an identity service", "person.crop.circle.fill"),
    "idle_detection": ("Idle Detection", "Know when you're using this device", "moon.fill"),
    "keyboard_lock": ("Keyboard", "Use your keyboard", "keyboard.fill"),
    "local_fonts": ("Fonts", "Use your computer's fonts", "textformat"),
    "local_network": ("Local Network", "Connect to devices on your local network", "network"),
    "loopback_network": ("Apps on This Device", "Connect to apps on this device", "laptopcomputer"),
    "mic_stream": ("Microphone", "Use your microphone", "mic.fill"),
    "midi_sysex": ("MIDI Devices", "Control and reprogram your MIDI devices", "pianokeys"),
    "multiple_downloads": ("Automatic Downloads", "Download multiple files", "arrow.down.circle.fill"),
    "nfc_device": ("NFC Devices", "Use NFC devices", "wave.3.right"),
    "notifications": ("Notifications", "Show notifications", "bell.fill"),
    "pointer_lock": ("Mouse Pointer", "Use your mouse pointer", "cursorarrow"),
    "protected_media_identifier": ("Protected Content", "Play protected content", "play.rectangle.fill"),
    "register_protocol_handler": ("Protocol Handlers", "Open links of a type", "link"),
    "sensors": ("Motion Sensors", "Use your motion sensors", "gyroscope"),
    "smart_card": ("Smart Cards", "Use your smart cards", "creditcard.fill"),
    "storage_access": ("Third-Party Cookies", "Use cookies and site data", "externaldrive.fill"),
    "top_level_storage_access": ("Third-Party Cookies", "Use cookies and site data", "externaldrive.fill"),
    "vr_session": ("Virtual Reality", "Use your virtual reality devices", "visionpro"),
    "web_app_installation": ("Web App Installation", "Install web apps", "app.badge.fill"),
    "web_printing": ("Printing", "Print", "printer.fill"),
    "window_management": ("Window Management", "Manage windows on all your displays", "macwindow.on.rectangle"),
  ]

  private static let wildcardTypes: [String: UTType] = ["image/*": .image, "audio/*": .audio, "video/*": .movie]

  func webContents(
    _ contents: ECWebContents, requestsPermissions permissions: [String], forOrigin origin: URL,
    completionHandler: @escaping (Bool) -> Void
  ) {
    guard let tab = tab(of: contents) else { return completionHandler(false) }
    // Asks "Allow http://… to access your location?".
    let asks = permissions.map { name in
      let text = Self.permissions[name]?.ask ?? name
      return text.prefix(1).lowercased() + text.dropFirst()
    }
    let site = origin.absoluteString.hasSuffix("/") ? String(origin.absoluteString.dropLast()) : origin.absoluteString
    permissionRequests[tab] = PermissionRequest(
      message: "Allow \(site) to \(ListFormatter.localizedString(byJoining: asks))?",
      isLocation: permissions == ["geolocation"]
    ) { [weak self] allowed in
      self?.permissionRequests[tab] = nil
      completionHandler(allowed)
    }
  }

  // Shown as a dialog centered over the dimmed page.
  @objc(webContents:runJavaScriptDialog:message:defaultText:completionHandler:)
  func webContents(
    _ contents: ECWebContents, runJavaScriptDialog type: ECJavaScriptDialogType, message: String,
    defaultText: String, completionHandler: @escaping (Bool, String) -> Void
  ) {
    guard let tab = tab(of: contents) else { return completionHandler(false, "") }
    let host = contents.url?.host().map { host in contents.url?.port.map { "\(host):\($0)" } ?? host }
    dialogs[tab] = PageDialog(
      type: type, title: type == .beforeUnload ? "Leave this page?" : "\(host ?? "This page") says",
      message: type == .beforeUnload ? "Changes you made may not be saved." : message, defaultText: defaultText
    ) { [weak self] accepted, text in
      self?.dialogs[tab] = nil
      completionHandler(accepted, text)
    }
  }

  func webContents(
    _ contents: ECWebContents, runFileChooserWithAcceptTypes acceptTypes: [String], allowsMultiple: Bool,
    directory: Bool, completionHandler: @escaping ([URL]?) -> Void
  ) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = !directory
    panel.canChooseDirectories = directory
    panel.allowsMultipleSelection = allowsMultiple
    panel.allowedContentTypes = acceptTypes.compactMap {
      $0.hasPrefix(".") ? UTType(filenameExtension: String($0.dropFirst())) : Self.wildcardTypes[$0] ?? UTType(mimeType: $0)
    }
    present(panel, for: contents, { panel.beginSheetModal(for: $0, completionHandler: $1) }) {
      completionHandler($0 == .OK ? panel.urls : nil)
    }
  }

  // Shows `sheet` on the tab's window once the tab is on screen; a closed tab is answered with `.abort`.
  private func present(
    _ sheet: NSWindow, for contents: ECWebContents,
    _ begin: @escaping (NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void,
    completion: @escaping (NSApplication.ModalResponse) -> Void
  ) {
    guard let tab = tab(of: contents) else { return completion(.abort) }
    guard let window = contents.view.window else {
      pendingSheets[tab, default: []].append { [weak self] in
        self?.present(sheet, for: contents, begin, completion: completion)
      }
      return
    }
    sheets[tab, default: []].append(sheet)
    begin(window) { [weak self] response in
      self?.sheets[tab]?.removeAll { $0 === sheet }
      completion(response)
    }
  }

  func webContents(_ contents: ECWebContents, didFindMatches matches: Int, activeMatch: Int) {
    guard let tab = tab(of: contents) else { return }
    Self.continuation.yield(.found(tab: tab, matches: matches, activeMatch: activeMatch))
  }

  func webContentsDidChangeZoom(_ contents: ECWebContents) {
    guard let tab = tab(of: contents) else { return }
    Self.continuation.yield(.zoomChanged(tab: tab, percent: contents.zoomPercent))
  }

  @objc(webContents:requestsInstallOfExtensionNamed:icon:permissions:completionHandler:)
  func webContents(
    _ contents: ECWebContents, requestsInstallOfExtensionNamed name: String, icon: NSImage?, permissions: [String],
    completionHandler: @escaping (Bool) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = "Add “\(name)”?"
    alert.informativeText =
      permissions.isEmpty
      ? "It requires no special permissions." : "It can:\n" + permissions.map { "• " + $0 }.joined(separator: "\n")
    alert.icon = icon
    alert.addButton(withTitle: "Add Extension")
    alert.addButton(withTitle: "Cancel")
    present(alert.window, for: contents, { alert.beginSheetModal(for: $0, completionHandler: $1) }) {
      completionHandler($0 == .alertFirstButtonReturn)
    }
  }

  // A link to another app (an OAuth sign-in handing back to a desktop app), asked as Chrome asks, with Cancel as the default.
  @objc(webContents:requestsOpeningURL:inApplicationNamed:fromOrigin:completionHandler:)
  func webContents(
    _ contents: ECWebContents, requestsOpeningURL url: URL, inApplicationNamed appName: String, fromOrigin origin: URL?,
    completionHandler: @escaping (Bool) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = "Open “\(appName)”?"
    alert.informativeText = "\(origin?.host() ?? "A website") wants to open this application."
    alert.addButton(withTitle: "Open \(appName)").keyEquivalent = ""
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
    present(alert.window, for: contents, { alert.beginSheetModal(for: $0, completionHandler: $1) }) {
      completionHandler($0 == .alertFirstButtonReturn)
    }
  }

  func webContents(_ contents: ECWebContents, didUpdateTargetURL url: URL?) {
    guard let tab = tab(of: contents) else { return }
    // Written only on change, so repeated events do not invalidate the views reading it.
    if hoveredLinks[tab] != url { hoveredLinks[tab] = url }
  }

  func webContents(_ contents: ECWebContents, didChangeSelection selectionText: String) {
    guard let tab = tab(of: contents) else { return }
    let selection = selectionText.isEmpty ? nil : selectionText
    if selections[tab] != selection { selections[tab] = selection }
  }

  func webContentsDidRequestClose(_ contents: ECWebContents) {
    guard let tab = tab(of: contents) else { return }
    Self.continuation.yield(.closeRequested(tab: tab))
  }

  // The page, link, image, selection and text field menus (Chromium's, without Cast).
  func webContents(_ contents: ECWebContents, showContextMenu menu: ECContextMenu) {
    guard let tab = tab(of: contents), let window = contents.view.window else { return }
    let open: (URL) -> Void = { Self.continuation.yield(.newWindowRequested(tab: tab, url: $0, background: false)) }
    let openWindow = { (url: URL, incognito: Bool) -> Void in
      Self.continuation.yield(.windowRequested(tab: tab, url: url, incognito: incognito))
    }
    let copy = { (string: String) in
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(string, forType: .string)
    }
    let selection = menu.selectionText
    let quoted = "“\(Self.truncated(selection))”"
    let flags = menu.editFlags
    var sections: [[NSMenuItem]] = []
    var developer: [NSMenuItem] = []
    if !selection.isEmpty, menu.linkURL == nil {
      sections.append([ActionMenuItem("Look Up \(quoted)") { menu.lookUp() }])
    }
    if let link = menu.linkURL {
      let isLittleSailfish = littleSailfishTabs.contains(tab)
      var opens = [ActionMenuItem("Open Link in New Tab") { open(link) }]
      // A Little Sailfish's menu is a shorter one: no background tab and no split view.
      if !isLittleSailfish {
        opens.append(ActionMenuItem("Open in Background Tab") {
          Self.continuation.yield(.newWindowRequested(tab: tab, url: link, background: true))
        })
      }
      opens.append(ActionMenuItem("Open Link in New Window") { openWindow(link, false) })
      if !isLittleSailfish {
        opens.append(ActionMenuItem("Open Link in Split View") {
          Self.continuation.yield(.splitRequested(tab: tab, url: link))
        })
      }
      // Incognito pages open no Little Sailfish.
      if !incognitoTabs.contains(tab) {
        opens.append(ActionMenuItem("Open Link in Little Sailfish") {
          Self.continuation.yield(.littleSailfishRequested(tab: tab, url: link))
        })
      }
      opens.append(ActionMenuItem("Open Link in Incognito Window") { openWindow(link, true) })
      sections += [
        opens,
        [
          ActionMenuItem("Save Link As…") { menu.saveLink() },
          ActionMenuItem("Copy Link Address") { copy(link.absoluteString) },
          ActionMenuItem("Copy Link as Markdown") {
            copy("[\(menu.linkText.isEmpty ? link.absoluteString : menu.linkText)](\(link.absoluteString))")
          },
        ],
      ]
    }
    if let image = menu.imageURL {
      var lens = URLComponents(string: "https://lens.google.com/uploadbyurl")!
      lens.queryItems = [URLQueryItem(name: "url", value: image.absoluteString)]
      sections.append([
        ActionMenuItem("Open Image in New Tab") { open(image) },
        ActionMenuItem("Save Image As…") { menu.saveImage() },
        ActionMenuItem("Copy Image") { menu.copyImage() },
        ActionMenuItem("Copy Image Address") { copy(image.absoluteString) },
        ActionMenuItem("Search Google for Image") { open(lens.url!) },
      ])
    }
    let search = ActionMenuItem("Search Google for \(quoted)") { open(CommandBarFeature.searchURL(selection)) }
    if menu.isEditable {
      let direction = NSMenuItem(title: "Writing Direction", action: nil, keyEquivalent: "")
      direction.submenu = NSMenu()
      direction.submenu?.items = [
        ActionMenuItem("Default", isEnabled: false) {},
        ActionMenuItem("Left to Right", isOn: menu.writingDirection == .leftToRight) {
          menu.setWritingDirection(.leftToRight)
        },
        ActionMenuItem("Right to Left", isOn: menu.writingDirection == .rightToLeft) {
          menu.setWritingDirection(.rightToLeft)
        },
      ]
      sections += [
        selection.isEmpty ? [] : [search],
        [ActionMenuItem("Emoji & Symbols") { NSApp.orderFrontCharacterPalette(nil) }],
        [ActionMenuItem("Import Passwords") { open(URL(string: "chrome://password-manager/settings")!) }],
        [
          ActionMenuItem("Undo", isEnabled: flags.contains(.canUndo)) { contents.undo(nil) },
          ActionMenuItem("Redo", isEnabled: flags.contains(.canRedo)) { contents.redo(nil) },
        ],
        [
          ActionMenuItem("Cut", isEnabled: flags.contains(.canCut)) { contents.cut(nil) },
          ActionMenuItem("Copy", isEnabled: flags.contains(.canCopy)) { contents.copy(nil) },
          ActionMenuItem("Paste", isEnabled: flags.contains(.canPaste)) { contents.paste(nil) },
          ActionMenuItem("Paste and Match Style", isEnabled: flags.contains(.canPaste)) {
            contents.pasteAndMatchStyle(nil)
          },
          ActionMenuItem("Select All", isEnabled: flags.contains(.canSelectAll)) { contents.selectAll(nil) },
        ],
        [ActionMenuItem("Language Settings") { open(URL(string: "chrome://settings/languages")!) }, direction],
      ]
    } else if !selection.isEmpty {
      // The search goes first on plain text and after the copy items on a link.
      let copies = [
        ActionMenuItem("Copy") { contents.copy(nil) },
        ActionMenuItem("Copy Link to Highlight") {
          contents.linkToHighlight { url in
            guard let url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
          }
        },
      ]
      sections.append((menu.linkURL == nil ? [search] + copies : copies + [search]) + [ActionMenuItem("Print…") { contents.print() }])
    } else if menu.linkURL == nil, menu.imageURL == nil, let url = contents.url {
      sections += [
        [
          ActionMenuItem("Back", isEnabled: contents.canGoBack) { contents.goBack() },
          ActionMenuItem("Forward", isEnabled: contents.canGoForward) { contents.goForward() },
          ActionMenuItem("Reload") { contents.reload() },
        ],
        [
          ActionMenuItem("Save As…") { contents.savePage() },
          ActionMenuItem("Print…") { contents.print() },
        ] + (contents.translationLanguage.map { [ActionMenuItem("Translate to \($0)") { contents.translate() }] } ?? []),
      ]
      // View Page Source is grouped with Inspect.
      developer.append(ActionMenuItem("View Page Source") { open(URL(string: "view-source:" + url.absoluteString)!) })
    }
    sections.append(developer + [ActionMenuItem("Inspect") { menu.inspect() }])
    if !selection.isEmpty {
      let speech = NSMenuItem(title: "Speech", action: nil, keyEquivalent: "")
      speech.submenu = NSMenu()
      speech.submenu?.items = [
        NSMenuItem(title: "Start Speaking", action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: ""),
        NSMenuItem(title: "Stop Speaking", action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: ""),
      ]
      sections.append([speech])
    }
    let items = NSMenu()
    items.items = Array(sections.filter { !$0.isEmpty }.flatMap { [.separator()] + $0 }.dropFirst())
    // A context menu event, so AppKit adds Services and Writing Tools for the page's view.
    let event = NSEvent.mouseEvent(
      with: .rightMouseDown, location: window.mouseLocationOutsideOfEventStream, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      eventNumber: 0, clickCount: 1, pressure: 1)!
    let view = window.firstResponder as? NSView
    NSMenu.popUpContextMenu(items, with: event, for: view?.isDescendant(of: contents.view) == true ? view! : contents.view)
  }

  // Chrome's selection text in menu items: 50 characters, cut at a word.
  private static func truncated(_ text: String) -> String {
    guard text.count > 50 else { return text }
    let prefix = text.prefix(50)
    return (prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix) + "…"
  }
}

private final class ActionMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(_ title: String, isEnabled: Bool = true, isOn: Bool = false, _ handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: isEnabled ? #selector(run) : nil, keyEquivalent: "")
    target = self
    state = isOn ? .on : .off
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  @objc private func run() {
    handler()
  }
}

struct PageDialog: Identifiable {
  let id = UUID()
  let type: ECJavaScriptDialogType
  let title: String
  let message: String
  let defaultText: String
  let answer: (Bool, String) -> Void
}

struct PermissionRequest: Identifiable {
  let id = UUID()
  let message: String
  let isLocation: Bool
  let answer: (Bool) -> Void
}
