import ComposableArchitecture
@preconcurrency import EngineCore
import Foundation
import WebKit

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // Fingerprinting protection for both engines in every profile, off by default.
  static var fingerprintingProtection: Self { Self[.appStorage("fingerprintingProtection"), default: false] }
}

extension SharedKey where Self == FileStorageKey<[String]>.Default {
  // The sites, by registrable domain, whose pages are left unprotected (Site Controls).
  static var fingerprintingExceptions: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "FingerprintingExceptions.json")), default: []]
  }
}

// What changes for a site's pages while fingerprinting protection is on. WebKit pages get Safari's Advanced
// Fingerprinting Protection through WebKit's private settings; Chromium 156 has none left to turn on, so Chromium pages
// run a main-world script in every frame that does the same.
@MainActor enum Fingerprinting {
  // Bit 6 of WebKit's private network connection integrity policy, Safari's fingerprinting protections: canvas and
  // audio readback noised per page load, and the window reported as the screen.
  static let webKitPolicyBit = 1 << 6

  static func isProtected(_ url: URL) -> Bool {
    @Shared(.fingerprintingProtection) var isOn
    @Shared(.fingerprintingExceptions) var exceptions
    return isOn && !exceptions.contains(Engine.shared.siteOf(url))
  }

  // Sets the protection for a WebKit page's main-frame navigation to `url`.
  static func apply(to preferences: WKWebpagePreferences, of webView: WKWebView, for url: URL) {
    guard preferences.responds(to: NSSelectorFromString("_setNetworkConnectionIntegrityPolicy:")) else { return }
    let isProtected = isProtected(url)
    let policy = preferences.value(forKey: "networkConnectionIntegrityPolicy") as! Int
    preferences.setValue(
      isProtected ? policy | webKitPolicyBit : policy & ~webKitPolicyBit, forKey: "networkConnectionIntegrityPolicy")
    webView.configuration.preferences.setValue(!isProtected, forKey: "shouldAllowUserInstalledFonts")
  }

  // Chromium pages that run the script. A page made while the setting is off gets it once the setting is first on.
  private static var scriptedPages: Set<UUID> = []
  // A noise seed for each context, so a site sees other values in another profile, in incognito and after a relaunch.
  private static let seeds = NSMapTable<ECBrowserContext, NSNumber>.weakToStrongObjects()
  // The script's configuration call is guarded by a value only this launch's scripts know.
  private static let secret = UUID().uuidString

  // A new Chromium page of the context gets the script while the setting is on.
  static func prepare(_ contents: ECWebContents, page: UUID, _ context: ECBrowserContext) {
    @Shared(.fingerprintingProtection) var isOn
    guard isOn else { return }
    contents.addDocumentStartScript(script(seed: seed(context)))
    scriptedPages.insert(page)
  }

  // The setting or an exception changed: a live Chromium page follows from its next load.
  static func update(_ contents: ECWebContents, page: UUID, _ context: ECBrowserContext) {
    @Shared(.fingerprintingProtection) var isOn
    if scriptedPages.contains(page) {
      contents.addDocumentStartScript(configuration())
    } else if isOn {
      contents.addDocumentStartScript(script(seed: seed(context)))
      scriptedPages.insert(page)
    }
  }

  private static func seed(_ context: ECBrowserContext) -> UInt32 {
    if let seed = seeds.object(forKey: context) {
      return seed.uint32Value
    }
    let seed = UInt32.random(in: .min ... .max)
    seeds.setObject(NSNumber(value: seed), forKey: context)
    return seed
  }

  private static func settings() -> (isOn: Bool, exceptions: String) {
    @Shared(.fingerprintingProtection) var isOn
    @Shared(.fingerprintingExceptions) var exceptions
    return (isOn, String(decoding: try! JSONEncoder().encode(exceptions), as: UTF8.self))
  }

  private static func script(seed: UInt32) -> String {
    let (isOn, exceptions) = settings()
    return source.replacing("__SECRET__", with: secret).replacing("__SEED__", with: String(seed))
      .replacing("__ENABLED__", with: String(isOn)).replacing("__EXCEPTIONS__", with: exceptions)
  }

  private static func configuration() -> String {
    let (isOn, exceptions) = settings()
    return "HTMLCanvasElement.prototype.toDataURL.call(\"\(secret)\").configure(\(isOn), \(exceptions));"
  }

  // Canvas readback (getImageData, toDataURL, toBlob, convertToBlob) flips the low bit of a color channel of about one
  // visible pixel in a hundred, chosen from the context's seed, the top-level host and the pixels, so the same read on
  // a page returns the same value. WebGL canvases are noised through toDataURL; readPixels is left alone, as WebKit
  // leaves it, since GPU picking reads single pixels. Audio buffers change by a millionth on one sample in 64. The
  // core count reads at most 8, the screen as the window, the WebGL renderer's Apple chip as "Apple GPU", and the
  // high-entropy client hints carry major versions only. The wrappers keep their native names, lengths and toString,
  // and a same-origin frame read through contentWindow or contentDocument is protected before its page script sees
  // it. A wrapped toDataURL called on the launch's secret returns the control that later configurations call.
  private static let source = #"""
    (() => {
      "use strict";
      const SECRET = "__SECRET__";
      const state = { enabled: __ENABLED__, exceptions: __EXCEPTIONS__ };
      const control = Object.freeze({
        configure(enabled, exceptions) {
          state.enabled = enabled;
          state.exceptions = exceptions;
        },
      });
      const { apply } = Reflect;
      const { defineProperty, getOwnPropertyDescriptor } = Object;
      const ancestors = location.ancestorOrigins;
      const top = ancestors && ancestors.length ? ancestors[ancestors.length - 1] : location.origin;
      const host = top === "null" ? "" : new URL(top).hostname;
      const active = () =>
        state.enabled && !state.exceptions.some((site) => host === site || host.endsWith("." + site));
      const mix = (a, b) => {
        let h = Math.imul(a ^ b, 0x9e3779b1);
        h = Math.imul(h ^ (h >>> 15), 0x85ebca77);
        return (h ^ (h >>> 13)) >>> 0;
      };
      let key = __SEED__;
      for (let i = 0; i < host.length; i++) key = mix(key, host.charCodeAt(i));

      const noisePixels = (data) => {
        const count = data.length >> 2;
        let h = mix(key, count);
        const stride = Math.max(1, Math.floor(count / 64));
        for (let p = 0; p < count; p += stride) {
          h = mix(h, data[p * 4] | (data[p * 4 + 1] << 8) | (data[p * 4 + 2] << 16) | (data[p * 4 + 3] << 24));
        }
        for (let p = h % 97; p < count; p += 50 + (h % 97)) {
          h = mix(h, p);
          if (data[p * 4 + 3] !== 0) data[p * 4 + (h % 3)] ^= 1;
        }
      };

      const masks = new WeakMap();
      const disguise = (wrapper, original) => {
        defineProperty(wrapper, "name", { value: original.name });
        defineProperty(wrapper, "length", { value: original.length });
        masks.set(wrapper, original);
        return wrapper;
      };
      const method = (proto, name, body) => {
        const d = proto && getOwnPropertyDescriptor(proto, name);
        if (!d || typeof d.value !== "function") return;
        const original = d.value;
        const wrapper = { [name](...args) { return body(original, this, args); } }[name];
        defineProperty(proto, name, { ...d, value: disguise(wrapper, original) });
      };
      const getter = (proto, name, body) => {
        const d = proto && getOwnPropertyDescriptor(proto, name);
        if (!d || !d.get) return;
        const original = d.get;
        const wrapper = getOwnPropertyDescriptor({ get [name]() { return body(original, this); } }, name).get;
        defineProperty(proto, name, { ...d, get: disguise(wrapper, original) });
      };
      const read = (original, self, value) => (active() ? value : apply(original, self, []));

      const install = (W) => {
        method(W.Function.prototype, "toString", (original, self, args) => apply(original, masks.get(self) || self, args));

        const canvas = W.HTMLCanvasElement.prototype;
        const context2d = W.CanvasRenderingContext2D.prototype;
        const { createElement } = W.Document.prototype;
        const { getContext, toBlob } = canvas;
        const { drawImage, getImageData, putImageData } = context2d;
        // A noised copy of the canvas; the canvas itself when it cannot be read (tainted or empty), so that the
        // original call fails as it would.
        const noisedCopy = (source) => {
          try {
            const copy = apply(createElement, W.document, ["canvas"]);
            copy.width = source.width;
            copy.height = source.height;
            const c = apply(getContext, copy, ["2d", { willReadFrequently: true }]);
            apply(drawImage, c, [source, 0, 0]);
            const image = apply(getImageData, c, [0, 0, copy.width, copy.height]);
            noisePixels(image.data);
            apply(putImageData, c, [image, 0, 0]);
            return copy;
          } catch {
            return source;
          }
        };
        method(canvas, "toDataURL", (original, self, args) =>
          self === SECRET ? control : apply(original, active() ? noisedCopy(self) : self, args));
        method(canvas, "toBlob", (original, self, args) => apply(original, active() ? noisedCopy(self) : self, args));
        method(W.OffscreenCanvas && W.OffscreenCanvas.prototype, "convertToBlob", (original, self, args) => {
          const copy = active() ? noisedCopy(self) : self;
          if (copy === self) return apply(original, self, args);
          const options = args[0] || {};
          return new W.Promise((resolve) => apply(toBlob, copy, [resolve, options.type, options.quality]));
        });
        for (const proto of [context2d, W.OffscreenCanvasRenderingContext2D && W.OffscreenCanvasRenderingContext2D.prototype]) {
          method(proto, "getImageData", (original, self, args) => {
            const image = apply(original, self, args);
            if (active()) noisePixels(image.data);
            return image;
          });
        }
        for (const proto of [W.WebGLRenderingContext.prototype, W.WebGL2RenderingContext && W.WebGL2RenderingContext.prototype]) {
          method(proto, "getParameter", (original, self, args) => {
            const value = apply(original, self, args);
            return active() && args[0] === 0x9246 && typeof value === "string"
              ? value.replace(/Apple M\d[^,)]*/, "Apple GPU")
              : value;
          });
        }

        const audio = W.AudioBuffer && W.AudioBuffer.prototype;
        if (audio) {
          const { getChannelData } = audio;
          const noised = new WeakSet();
          const noiseBuffer = (buffer) => {
            if (!active() || noised.has(buffer)) return;
            noised.add(buffer);
            for (let c = 0; c < buffer.numberOfChannels; c++) {
              const data = apply(getChannelData, buffer, [c]);
              for (let i = mix(key, c) % 64; i < data.length; i += 64) {
                data[i] += data[i] * (mix(key, i) & 1 ? 1e-6 : -1e-6);
              }
            }
          };
          for (const name of ["getChannelData", "copyFromChannel"]) {
            method(audio, name, (original, self, args) => {
              noiseBuffer(self);
              return apply(original, self, args);
            });
          }
        }

        getter(W.Navigator.prototype, "hardwareConcurrency", (original, self) =>
          active() ? Math.min(apply(original, self, []), 8) : apply(original, self, []));
        const screen = W.Screen.prototype;
        getter(screen, "width", (original, self) => read(original, self, W.innerWidth));
        getter(screen, "availWidth", (original, self) => read(original, self, W.innerWidth));
        getter(screen, "height", (original, self) => read(original, self, W.innerHeight));
        getter(screen, "availHeight", (original, self) => read(original, self, W.innerHeight));
        getter(screen, "availLeft", (original, self) => read(original, self, 0));
        getter(screen, "availTop", (original, self) => read(original, self, 0));
        method(W.NavigatorUAData && W.NavigatorUAData.prototype, "getHighEntropyValues", (original, self, args) => {
          const values = apply(original, self, args);
          if (!active()) return values;
          const major = (version) => version.split(".")[0];
          return values.then((v) => {
            if (v.platformVersion) v.platformVersion = major(v.platformVersion) + ".0.0";
            if (v.uaFullVersion) v.uaFullVersion = major(v.uaFullVersion) + ".0.0.0";
            if (v.fullVersionList) {
              v.fullVersionList = v.fullVersionList.map(({ brand, version }) => ({ brand, version: major(version) + ".0.0.0" }));
            }
            return v;
          });
        });

        // A frame's own window, as a script reaches it to step around this one's wrappers. A cross-origin frame runs
        // this script itself, and reading its prototypes throws.
        const protect = (win) => {
          try {
            if (win && !masks.has(win.HTMLCanvasElement.prototype.toDataURL)) install(win);
          } catch {}
        };
        for (const element of [W.HTMLIFrameElement, W.HTMLFrameElement, W.HTMLObjectElement]) {
          getter(element.prototype, "contentWindow", (original, self) => {
            const win = apply(original, self, []);
            protect(win);
            return win;
          });
          getter(element.prototype, "contentDocument", (original, self) => {
            const doc = apply(original, self, []);
            if (doc) protect(doc.defaultView);
            return doc;
          });
        }
      };
      install(window);
    })();
    """#
}

extension Engine {
  // The setting or an exception changed.
  func fingerprintingDidChange() {
    for case let (id, contents as ECWebContents) in livePages {
      if let tab = tab(of: contents), let context = tabContexts[tab] {
        Fingerprinting.update(contents, page: id, context)
      }
    }
  }

  // Site Controls: the site of the tab's page loses or regains protection, and the page loads again with it.
  func setFingerprintingProtection(_ isOn: Bool, forSiteOf url: URL, in tab: UUID) {
    @Shared(.fingerprintingExceptions) var exceptions
    let site = siteOf(url)
    $exceptions.withLock { exceptions in
      exceptions.removeAll { $0 == site }
      if !isOn {
        exceptions.append(site)
      }
    }
    fingerprintingDidChange()
    page(tab)?.reload()
  }
}
