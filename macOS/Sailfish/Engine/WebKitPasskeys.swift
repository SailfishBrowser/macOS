import AuthenticationServices
import Foundation
import Security

// Passkeys on WebKit pages: macOS runs WebAuthn for an app carrying Apple's browser passkey entitlement; without it the
// page sees no WebAuthn, so sites offer passwords.
@MainActor enum WebKitPasskeys {
  static let isEntitled: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(
      task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
    return value as? Bool == true
  }()

  private static var askedForAccess = false

  // Asks macOS, once per launch and only while undecided, to let WebKit pages use the user's passkeys.
  static func requestAccess() {
    guard !askedForAccess else { return }
    askedForAccess = true
    let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    guard manager.authorizationStateForPlatformCredentials == .notDetermined else { return }
    manager.requestAuthorizationForPublicKeyCredentials { _ in }
  }

  // Runs at document start in the page world of every frame of an app without the entitlement.
  static let hidingScript = """
    (() => {
      delete window.PublicKeyCredential;
      if (!window.CredentialsContainer) return;
      const container = CredentialsContainer.prototype;
      for (const name of ["create", "get"]) {
        const original = container[name];
        container[name] = function (options) {
          return typeof options === "object" && options !== null && "publicKey" in options
            ? Promise.reject(new DOMException("Passkeys are not available.", "NotSupportedError"))
            : original.apply(this, arguments);
        };
      }
    })();
    """
}
