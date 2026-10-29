import AppKit
import ComposableArchitecture
@preconcurrency import EngineCore

extension Engine: @preconcurrency ECExtensionsDelegate {
  func browserContextExtensionsDidChange(_ context: ECBrowserContext) {
    extensionsRevision += 1
  }

  func browserContext(
    _ context: ECBrowserContext, actionDidChangeForExtension identifier: String, webContents: ECWebContents?
  ) {
    extensionsRevision += 1
  }

  // The enabled extensions' actions for a live tab of the space.
  func extensionActions(_ tab: UUID, in space: Space) -> [ExtensionAction] {
    extensionActions(tab, profile: space.profileID, incognito: space.isIncognito)
  }

  func extensionActions(_ tab: UUID, profile: UUID, incognito: Bool = false) -> [ExtensionAction] {
    _ = extensionsRevision
    guard let contents = tabs[tab] else { return [] }
    let context = loadedContext(profile, incognito)
    return context.extensions.filter(\.isEnabled).compactMap { item in
      context.action(forExtension: item.identifier, in: contents).map {
        ExtensionAction(extension: item, action: $0, context: context, profile: profile)
      }
    }
  }

  func runExtensionAction(_ id: String, _ tab: UUID, in space: Space) -> ECExtensionPopup? {
    runExtensionAction(id, tab, profile: space.profileID, incognito: space.isIncognito)
  }

  func runExtensionAction(_ id: String, _ tab: UUID, profile: UUID, incognito: Bool = false) -> ECExtensionPopup? {
    tabs[tab].flatMap { loadedContext(profile, incognito).runAction(forExtension: id, in: $0) }
  }
}

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // The built-in ad blocker, on by default in every profile.
  static var blocksAds: Self { Self[.appStorage("blocksAds"), default: true] }
}

extension Engine {
  // uBlock Origin, from scripts/fetch-ublock.sh.
  static let adBlocker = Bundle.main.path(forResource: "uBlock0.chromium", ofType: nil)!

  // Chromium pages block with uBlock Origin itself, and WebKit pages with its lists as content rules.
  func applyAdBlocking(_ context: ECBrowserContext) {
    @Shared(.blocksAds) var blocksAds
    if blocksAds {
      context.loadBuiltInExtension(atPath: Self.adBlocker)
      ContentBlocker.start()
    } else {
      context.unloadBuiltInExtensions()
      ContentBlocker.stop()
    }
  }

  func adBlockingDidChange() {
    contexts.values.forEach(applyAdBlocking)
    ContentBlocker.applyToLivePages()
  }
}

// An extension with its action for one tab, and the profile's context that runs and manages it.
struct ExtensionAction {
  let `extension`: ECExtension
  let action: ECExtensionAction
  let context: ECBrowserContext
  let profile: Profile.ID

  var id: String { `extension`.identifier }
}

extension SharedKey where Self == FileStorageKey<[Profile.ID: [String]]>.Default {
  // Each profile's extensions pinned to the URL pill, in the order they were pinned: extensions belong to a
  // profile, so each profile has its own row of them.
  static var pinnedExtensions: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "PinnedExtensions.json")), default: [:]]
  }
}

// Asks before removing an extension.
@MainActor func confirmRemoval(of item: ECExtension, from context: ECBrowserContext) {
  let alert = NSAlert()
  alert.messageText = "Remove “\(item.name)”?"
  alert.addButton(withTitle: "Remove")
  alert.addButton(withTitle: "Cancel")
  alert.icon = item.icon
  guard alert.runModal() == .alertFirstButtonReturn else { return }
  context.uninstallExtension(item.identifier)
  @Shared(.pinnedExtensions) var pinned
  $pinned.withLock { pinned in
    for profile in pinned.keys {
      pinned[profile]?.removeAll { $0 == item.identifier }
    }
  }
}

@MainActor @Observable
final class ExtensionPopup: NSObject, @preconcurrency ECExtensionPopupDelegate {
  @ObservationIgnored let popup: ECExtensionPopup
  var size: NSSize
  var isOpen = true

  init(_ popup: ECExtensionPopup) {
    self.popup = popup
    size = popup.size
    super.init()
    popup.delegate = self
  }

  func close() {
    guard isOpen else { return }
    isOpen = false
    popup.close()
  }

  func extensionPopupDidResize(_ popup: ECExtensionPopup) {
    size = popup.size
  }

  func extensionPopupDidClose(_ popup: ECExtensionPopup) {
    isOpen = false
  }
}
