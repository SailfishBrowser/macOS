import AppKit
@preconcurrency import EngineCore
import WebKit

// Saved Chromium logins on WebKit pages: filled into sign-in forms and offered under a focused username field.
@MainActor enum PasswordFill {
  static let world = WKContentWorld.world(name: "SailfishPasswords")
  // The message handler's name in `world`.
  static let handlerName = "passwords"

  // Runs at document end in every frame. It numbers each sign-in form (a rendered password field, the only one of its
  // form, and the nearest rendered text or email input before it) and reports it, and reports a username field focused
  // by the user with its rectangle in the top frame where it can be measured.
  static let script = """
    (() => {
      const post = (body) => webkit.messageHandlers.\(handlerName).postMessage(body);
      const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
      const forms = [];
      const fieldForms = new WeakMap();
      const rendered = (input) => {
        const rect = input.getBoundingClientRect();
        return input.offsetParent !== null && rect.width > 0 && rect.height > 0;
      };
      const passwords = (scope) => [...scope.querySelectorAll("input[type=password]")];
      const usernameFor = (password) => {
        const inputs = [...(password.form || document).querySelectorAll("input")];
        for (let i = inputs.indexOf(password) - 1; i >= 0; i--) {
          const input = inputs[i];
          if ((input.type === "text" || input.type === "email") && rendered(input)) return input;
        }
        return null;
      };
      const scan = () => {
        for (const password of passwords(document)) {
          if (fieldForms.has(password) || !rendered(password)) continue;
          if (password.form && passwords(password.form).filter(rendered).length !== 1) continue;
          const username = usernameFor(password);
          const form = forms.push({ username, password }) - 1;
          fieldForms.set(password, form);
          if (username) fieldForms.set(username, form);
          post({ type: "form", form });
        }
      };
      const rectOf = (input) => {
        let { left, top, width, height } = input.getBoundingClientRect();
        for (let view = window; view !== view.top; view = view.parent) {
          const frame = view.frameElement;
          if (!frame) return null;
          const rect = frame.getBoundingClientRect();
          left += rect.left + frame.clientLeft;
          top += rect.top + frame.clientTop;
        }
        return [left, top, width, height];
      };
      // The username field, or the password field of a form without one.
      document.addEventListener("focusin", (event) => {
        scan();
        const form = fieldForms.get(event.target);
        if (form === undefined || !navigator.userActivation.isActive) return;
        const entry = forms[form];
        if (event.target !== (entry.username || entry.password)) return;
        post({ type: "focus", form, rect: rectOf(event.target) });
      }, true);
      let scheduled = false;
      new MutationObserver(() => {
        if (scheduled) return;
        scheduled = true;
        setTimeout(() => {
          scheduled = false;
          scan();
        }, 250);
      }).observe(document, { childList: true, subtree: true });
      // Called by Sailfish with the login as arguments. An automatic fill leaves a form the user has started alone.
      globalThis.sailfishFill = (form, username, password, automatic) => {
        const entry = forms[form];
        if (!entry || !entry.password.isConnected || !rendered(entry.password)) return;
        const name = entry.username && rendered(entry.username) ? entry.username : null;
        if (automatic && (entry.password.value || (name && name.value && name.value !== username))) return;
        for (const [input, value] of [[name, username], [entry.password, password]]) {
          if (!input) continue;
          setValue.call(input, value);
          input.dispatchEvent(new Event("input", { bubbles: true }));
          input.dispatchEvent(new Event("change", { bubbles: true }));
        }
      };
      scan();
    })();
    """

  // A saved login as `loginsForURL:` gives it.
  private struct Login: Sendable {
    let url: String
    let username: String
    let password: String
    let isExactMatch: Bool
  }

  static func handle(_ message: WKScriptMessage, page: WebKitPage) {
    let engine = Engine.shared
    let frame = message.frameInfo
    guard let body = message.body as? [String: Any], let tab = engine.tab(of: page),
      let context = engine.tabContexts[tab], let origin = url(of: frame.securityOrigin)
    else { return }
    switch body["type"] as? String {
    case "form":
      guard let form = body["form"] as? Int, frame.isMainFrame || isSameSite(origin, page.committedURL) else { return }
      Task {
        guard let login = await logins(context, origin).first(where: \.isExactMatch) else { return }
        fill(page, frame, form: form, login, automatic: true)
      }
    case "focus":
      guard let form = body["form"] as? Int else { return }
      let rect = body["rect"] as? [Double]
      Task {
        let saved = await logins(context, origin)
        guard !saved.isEmpty, engine.shownTab(of: page) == tab, page.webView.window?.isKeyWindow == true
        else { return }
        showMenu(saved, page, frame, form: form, rect: rect?.count == 4 ? rect : nil)
      }
    default: return
    }
  }

  // The frame's origin as a URL, for http and https frames only.
  private static func url(of origin: WKSecurityOrigin) -> URL? {
    guard origin.protocol == "https" || origin.protocol == "http", !origin.host.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = origin.protocol
    components.host = origin.host
    components.port = origin.port == 0 ? nil : origin.port
    components.path = "/"
    return components.url
  }

  private static func isSameSite(_ origin: URL, _ page: URL?) -> Bool {
    guard let page else { return false }
    return page.scheme == origin.scheme && Engine.shared.siteOf(page) == Engine.shared.siteOf(origin)
  }

  // The logins Chrome would offer on the origin, most recently used exact matches first; an http origin gets only
  // logins saved for http.
  private static func logins(_ context: ECBrowserContext, _ origin: URL) async -> [Login] {
    let logins = await withCheckedContinuation { continuation in
      context.logins(for: origin) { found in
        continuation.resume(
          returning: found.map {
            Login(url: $0.urlString, username: $0.username, password: $0.password, isExactMatch: $0.isExactMatch)
          })
      }
    }
    return origin.scheme == "https" ? logins : logins.filter { URL(string: $0.url)?.scheme == "http" }
  }

  // Fills the login into the frame's form, in the frame's password world, passing the values as arguments.
  private static func fill(_ page: WebKitPage, _ frame: WKFrameInfo, form: Int, _ login: Login, automatic: Bool) {
    page.webView.callAsyncJavaScript(
      "sailfishFill(form, username, password, automatic)",
      arguments: ["form": form, "username": login.username, "password": login.password, "automatic": automatic],
      in: frame, in: world, completionHandler: nil)
  }

  // Every login's username under the field, or at the mouse when the field sits in a frame that cannot be measured.
  private static func showMenu(
    _ logins: [Login], _ page: WebKitPage, _ frame: WKFrameInfo, form: Int, rect: [Double]?
  ) {
    let menu = NSMenu()
    for login in logins {
      menu.addItem(ActionMenuItem(login.username.isEmpty ? "No Username" : login.username) {
        fill(page, frame, form: form, login, automatic: false)
      })
    }
    let view = page.webView
    let point = rect.map { rect in
      let zoom = view.pageZoom
      let bottom = (rect[1] + rect[3]) * zoom + 4
      return NSPoint(x: rect[0] * zoom, y: view.isFlipped ? bottom : view.bounds.height - bottom)
    }
    MenuPopUp(menu: menu, point: point ?? NSEvent.mouseLocation, view: point == nil ? nil : view).show()
  }
}

// Pops a menu from the run loop rather than from a main-actor job, so the main actor keeps running while it shows.
@MainActor private final class MenuPopUp: NSObject {
  let menu: NSMenu
  let point: NSPoint
  let view: NSView?

  init(menu: NSMenu, point: NSPoint, view: NSView?) {
    self.menu = menu
    self.point = point
    self.view = view
  }

  func show() {
    perform(#selector(popUp), with: nil, afterDelay: 0)
  }

  @objc private func popUp() {
    menu.popUp(positioning: nil, at: point, in: view)
  }
}
