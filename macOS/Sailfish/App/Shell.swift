import AppKit
import ComposableArchitecture
@preconcurrency import EngineCore
import OSLog

@MainActor
final class Shell: NSObject, NSMenuDelegate {
  // The quit save and the reducer's debounced saves share it, so every snapshot write goes through its lock.
  private let writer: SnapshotWriter<Snapshot>
  // Restore Data reads the backups and writes the pre-restore one through the same client the writer uses.
  @Dependency(\.persistence) private var persistence
  @Dependency(\.macTabs) private var macTabs
  let store: StoreOf<AppFeature>
  var controllers: [WindowFeature.State.ID: WindowController] = [:]
  var littleSailfishes: [LittleSailfishFeature.State.ID: LittleSailfishWindowController] = [:]
  private var windowsToken: ObserveToken?
  private var littleSailfishesToken: ObserveToken?
  private var extensionWindowsToken: ObserveToken?
  // What each space's extension window was last synced from, so unchanged spaces skip the sync.
  var extensionWindowKeys: [Space.ID: ExtensionWindowKey] = [:]
  private lazy var quitWarning = QuitWarning(store: store) { [weak self] in self?.controllers[$0]?.showWindow(nil) }
  #if !DEBUG
    // Created at launch, as nothing may touch NSApp before ChromeMain.
    private(set) lazy var updater = Updater { [weak self] in
      self?.quitWarning.bypass = true
    } updateReady: { [weak self] in
      self?.store.send(.updateReady($0))
    }
  #endif
  private lazy var littleSailfishHotKey = LittleSailfishHotKey { [weak self] in self?.store.send(.newLittleSailfish) }
  private lazy var settings = makeSettingsWindow(store: store) { [weak self] url, profile in
    guard let self else { return }
    store.send(.openPage(url, profile: profile))
    store.state.window(using: profile).map { controllers[$0.id]?.showWindow(nil) }
  } importData: { [weak self] in
    self?.importData()
  }

  private var recoveryToken: ObserveToken?
  private var warmToken: ObserveToken?

  override init() {
    let writer = SnapshotWriter<Snapshot>.state
    self.writer = writer
    store = Store(initialState: AppFeature.State()) { AppFeature(writer: writer) }
    super.init()
  }

  func launch() {
    #if !DEBUG
      _ = updater
    #endif
    NSApp.mainMenu = mainMenu()
    MenuShortcuts.apply(to: NSApp.mainMenu!)
    ECEngine.dockMenu = dockMenu()
    SoundEffect.register()
    recoveryToken = observe { [weak self] in self?.showRecoveredSpaces() }
    warmToken = observe { [weak self] in self?.warmWebKit() }
    Engine.shared.windowDelegate = self
    // Separate observations, so a page update that reaches one sync does not run the others.
    windowsToken = observe { [weak self] in self?.syncWindows() }
    littleSailfishesToken = observe { [weak self] in self?.syncLittleSailfishes() }
    extensionWindowsToken = observe { [weak self] in self?.syncExtensionWindows() }
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] notification in
        let window = (notification.object as AnyObject?).map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
          guard let self else { return }
          if name == NSWindow.didBecomeKeyNotification,
            let id = self.controllers.first(where: { $0.value.window.map(ObjectIdentifier.init) == window })?.key
          {
            self.store.send(.windowFocused(id))
          }
          self.syncExtensionWindows()
        }
      }
    }
    _ = littleSailfishHotKey
    quitWarning.install()
    applyAppIcon()
    store.send(.launched)
    // Checks each minute for Today tabs to archive.
    Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { _ = self?.store.send(.archiveIdleTabs) }
    }
    NSApp.activate()
  }

  func terminate() {
    Engine.shared.closeAll()
    do {
      try writer.flush()
    } catch {
      Logger().error("Saving state on quit failed: \(error)")
    }
    // The last change to the spaces reaches iCloud, waiting at most two seconds.
    let macTabs = macTabs
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      await macTabs.flush()
      done.signal()
    }
    _ = done.wait(timeout: .now() + 2)
  }

  // From the Dock menu the app may not be frontmost, so the window is brought forward.
  @objc func newWindow(_ sender: Any?) {
    store.send(.newWindow)
    NSApp.activate()
  }

  @objc func newIncognitoWindow(_ sender: Any?) {
    store.send(.newIncognitoWindow)
    NSApp.activate()
  }

  @objc func newLittleSailfish(_ sender: Any?) {
    store.send(.newLittleSailfish)
  }

  // ⌘W closes the tab in a browser window, and Settings or any other window when that is key.
  @objc func closeTab(_ sender: Any?) {
    guard let window = NSApp.keyWindow else { return }
    if let controller = (window.sheetParent ?? window.parent ?? window).windowController as? WindowController {
      controller.closeTab(sender)
    } else {
      window.performClose(sender)
    }
  }

  // ⇧⌘T brings back whichever closed last: the key window's page, or a Little Sailfish.
  @objc func reopenClosedTab(_ sender: Any?) {
    let window = NSApp.keyWindow.map { $0.sheetParent ?? $0.parent ?? $0 }
    let controller = window?.windowController as? WindowController
    let closedPage = controller?.store.undoStack.last(where: \.isClosedPage)?.closedAt
    if let closedPage, closedPage > store.closedLittleSailfishes.last?.closedAt ?? .distantPast {
      controller?.reopenClosedTab(sender)
    } else if !store.closedLittleSailfishes.isEmpty {
      store.send(.reopenLittleSailfish)
    } else {
      controller?.reopenClosedTab(sender)
    }
  }

  // The Tabs menu shows Open in <space> only while a Little Sailfish is key.
  func menuNeedsUpdate(_ menu: NSMenu) {
    let isLittleSailfish = NSApp.keyWindow?.windowController is LittleSailfishWindowController
    for item in menu.items where item.action == #selector(LittleSailfishWindowController.openInSpace(_:)) {
      item.isHidden = !isLittleSailfish
    }
  }

  @objc func showAllLittleSailfishes(_ sender: Any?) {
    littleSailfishes.values.forEach { $0.showWindow(nil) }
    NSApp.activate()
  }

  @objc func closeAllLittleSailfishes(_ sender: Any?) {
    Array(littleSailfishes.values).forEach { $0.close() }
  }

  // Help > Restore Data: a list of the sidebar backups; the chosen one takes the sidebar's place.
  @objc func restoreData(_ sender: Any?) {
    guard let window = NSApp.keyWindow ?? controllers.values.first?.window else { return }
    do {
      let entries = try persistence.backups().compactMap { backup in
        // A backup that does not read any more is left out.
        (try? Snapshot.decode(persistence.loadBackup(backup))).map { BackupEntry(backup: backup, snapshot: $0) }
      }
      presentModal(over: window) { [store, persistence] dismiss in
        RestoreDataDialog(
          entries: entries,
          restore: { snapshot in
            // The sidebar as it is now goes into the backups first; without that copy nothing is replaced.
            do {
              try persistence.backup(store.snapshot!.encoded())
            } catch {
              let alert = NSAlert()
              alert.messageText = "The sidebar was not backed up"
              alert.informativeText = "Nothing was restored. \(error.localizedDescription)"
              alert.runModal()
              return
            }
            store.send(.restoreBackup(snapshot))
          },
          dismiss: dismiss)
      }
    } catch {
      Logger().error("Backups not listed: \(error)")
    }
  }

  // Help > Troubleshooting > Reveal Data: the app's data folder in the Finder.
  @objc func revealData(_ sender: Any?) {
    NSWorkspace.shared.activateFileViewerSelecting([URL.dataDirectory])
  }

  // Help > Troubleshooting > Copy Info: the versions a bug report needs, on the pasteboard, with a toast.
  @objc func copyInfo(_ sender: Any?) {
    let appName = ProcessInfo.processInfo.processName
    let bundle = Bundle.main
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    let macOS = ProcessInfo.processInfo.operatingSystemVersionString
    let engine = Bundle(for: ECBrowserContext.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let info = "\(appName) \(version) (\(build))\nEngine \(engine)\nmacOS \(macOS)\nBundle \(bundle.bundleIdentifier ?? "")"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(info, forType: .string)
    let window = (NSApp.keyWindow?.windowController as? WindowController) ?? controllers.values.first
    window?.store.send(.showToast("Copied \(appName) Info!"))
  }

  // Spaces whose profile is missing on this computer revert to Default, which is said once.
  private func showRecoveredSpaces() {
    let spaces = store.recoveredSpaces
    guard !spaces.isEmpty, store.isLoaded else { return }
    let alert = NSAlert()
    alert.messageText = spaces.count == 1 ? "A Profile was missing on this computer" : "Profiles were missing on this computer"
    alert.informativeText =
      "The \(spaces.map { "“\($0)”" }.formatted(.list(type: .and))) \(spaces.count == 1 ? "Space uses" : "Spaces use") the Default Profile now."
    alert.runModal()
    store.send(.dismissRecoveredSpaces)
  }

  // Once the saved windows have loaded, each profile with a tab showing a WebKit page starts WebKit, on the turn after
  // the windows' first frame, so its first WebKit page opens as fast as later ones. Any other profile starts it when a
  // hovered link or a typed address would open in WebKit. Runs once.
  private func warmWebKit() {
    guard store.isLoaded else { return }
    // NSObject keeps every observation token it returns, so only cancelling ends this one.
    warmToken?.cancel()
    let profiles = Set(
      store.windows.flatMap(\.spaces.spaces).filter { $0.tabs.contains { $0.engine == .webkit } }.map(\.profileID))
    DispatchQueue.main.async {
      for profile in profiles {
        WebKitStores.warm(profile: profile, incognito: false)
      }
    }
  }

  nonisolated static var isDefaultBrowser: Bool {
    NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https:")!) == Bundle.main.bundleURL
  }

  // macOS asks the user to confirm, and sets the app for http and https together.
  static func makeDefaultBrowser() async {
    try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http")
  }

  // Share Sailfish: the Library's gift card, over the key window.
  @objc func shareSailfish(_ sender: Any?) {
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
    presentModal(over: window) { ShareSailfish(dismiss: $0) }
  }

  @objc func setAsDefaultBrowser(_ sender: Any?) {
    Task { await Self.makeDefaultBrowser() }
  }

  // Settings > Import Data: the import opens over the last regular window, a new one if there is none.
  private func importData() {
    if !store.windows.contains(where: { !$0.isIncognito }) {
      store.send(.newWindow)
    }
    let id = (store.focusedWindowID.flatMap { store.windows[id: $0] }.flatMap { $0.isIncognito ? nil : $0 }
      ?? store.windows.last { !$0.isIncognito })!.id
    store.send(.windows(.element(id: id, action: .showImport)))
    syncWindows()
    controllers[id]?.showWindow(nil)
  }

  // Opens the pane the sender's tag picks, as the command bar's Edit Keyboard Shortcuts does.
  @objc func showSettings(_ sender: Any?) {
    (settings.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = (sender as? NSMenuItem)?.tag ?? 0
    settings.makeKeyAndOrderFront(nil)
  }

  private func syncWindows() {
    // A window Restore Data took out of the state closes; its controller's close callback finds nothing to remove.
    for (id, controller) in controllers where store.windows[id: id] == nil {
      controller.close()
    }
    for windowStore in store.scope(state: \.windows, action: \.windows) {
      let id = windowStore.state.id
      guard controllers[id] == nil else { continue }
      let downloads = store.scope(state: \.downloads, action: \.downloads)
      let controller = WindowController(store: windowStore, downloads: downloads) { [weak self] in
        self?.controllers[id] = nil
        self?.store.send(.windowClosed(id))
        self?.syncExtensionWindows()
      }
      // A window opened while the key window is in full screen opens in full screen too.
      let isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
      controllers[id] = controller
      controller.showWindow(nil)
      if isFullScreen { controller.window?.toggleFullScreen(nil) }
    }
  }

  private func syncLittleSailfishes() {
    Engine.shared.littleSailfishTabs = Set(store.littleSailfishes.compactMap(\.tab?.id))
    for (id, controller) in littleSailfishes where store.littleSailfishes[id: id] == nil {
      controller.close()
    }
    for littleSailfish in store.scope(state: \.littleSailfishes, action: \.littleSailfishes) where littleSailfishes[littleSailfish.state.id] == nil {
      let id = littleSailfish.state.id
      let controller = LittleSailfishWindowController(store: littleSailfish, app: store) { [weak self] space in
        guard let self else { return }
        store.send(.openLittleSailfish(id, in: space))
        controllers[store.windows.first { $0.spaces.spaces[id: space] != nil }!.id]?.showWindow(nil)
      } onClose: { [weak self] frame in
        self?.littleSailfishes[id] = nil
        self?.store.send(.littleSailfishClosed(id, frame: frame))
      }
      littleSailfishes[id] = controller
      controller.showWindow(nil)
      NSApp.activate()
    }
    let littleSailfishActions: [Selector?] = [#selector(showAllLittleSailfishes(_:)), #selector(closeAllLittleSailfishes(_:))]
    for item in ECEngine.dockMenu?.items ?? [] where littleSailfishActions.contains(item.action) {
      item.isEnabled = !littleSailfishes.isEmpty
    }
  }
}
