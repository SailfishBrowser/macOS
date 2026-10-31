import AppKit
import ComposableArchitecture
@preconcurrency import EngineCore

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // "Always use secure connections": Chrome's HTTPS-First strict mode in every profile.
  static var httpsOnly: Self { Self[.appStorage("httpsOnly"), default: false] }
}

extension Engine {
  // Chromium pages: Chrome's https_only_mode_enabled pref, which an incognito context reads through from its profile.
  func applyHTTPSOnly(_ context: ECBrowserContext) {
    @Shared(.httpsOnly) var httpsOnly
    context.httpsOnlyModeEnabled = httpsOnly
  }

  func httpsOnlyDidChange() {
    contexts.values.forEach(applyHTTPSOnly)
  }
}
