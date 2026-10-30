// Copyright 2026 Mantra Patel. Licensed under the Apache License 2.0.
// Adapted from the protected-media detector in Ardia's packages/ardiacore/ios/page_script.js, lines 763 to 833, at
// a01a909; Sailfish changed it.

import ComposableArchitecture
@preconcurrency import EngineCore
import Foundation

// "Play {site} in WebKit?" on the URL pill, for a Chromium page whose protected video failed. `page` is the page that
// asked, and leaving it withdraws the offer.
struct EngineOffer: Identifiable {
  let id: UUID
  let tab: UUID
  let page: UUID
  let site: String
  let answer: (_ open: Bool, _ remember: Bool) -> Void
}

// The script every Chromium page runs in its main world at document start, and the object it reports through.
enum ProtectedMedia {
  static let objectName = "sailfishProtectedMedia"

  // It wraps requestMediaKeySystemAccess for the Widevine, PlayReady and FairPlay key systems. After one of them is
  // refused, the top frame posts the key system once: when a media element asked to play has not progressed five
  // seconds later, when an encrypted or waitingforkey event's element still has no keys two seconds later, on a
  // decode error, or when a refusal during user activation is followed by no progress for five seconds. A clear
  // video that only probes for Widevine plays, so it never posts. The object leaves the page's globals at once.
  static let script = #"""
    (() => {
      "use strict";
      const channel = window.sailfishProtectedMedia;
      Reflect.deleteProperty(window, "sailfishProtectedMedia");
      const NavigatorType = window.Navigator;
      const requestAccess = NavigatorType && NavigatorType.prototype.requestMediaKeySystemAccess;
      if (!channel || window !== window.top || typeof requestAccess !== "function") return;
      const apply = Reflect.apply;
      const post = channel.postMessage;
      const guard = (fn) =>
        function () {
          try {
            return apply(fn, this, arguments);
          } catch (e) {}
        };
      const protectedSystem = /^com\.(widevine\.alpha|microsoft\.playready|apple\.fps)/;
      const { test } = RegExp.prototype;
      const then = Promise.prototype.then;
      const GRACE_MS = 5000;
      const KEYS_GRACE_MS = 2000;
      const MEDIA_ERR_DECODE = 3;
      let sent = false;
      let refused = "";
      const attempted = new Set();
      const needsProtectedPlayback = (keySystem) => {
        if (sent) return;
        sent = true;
        apply(post, channel, [keySystem]);
      };
      const progressed = (m) => m.readyState >= 2 && m.currentTime > 0;
      const anyProgressed = () => [...attempted, ...document.querySelectorAll("video, audio")].some(progressed);
      const after = (ms, fn) => setTimeout(guard(fn), ms);
      const stalled = (m) => !m.paused && !m.ended && !progressed(m);
      const judgeAttempt = (m) =>
        after(GRACE_MS, () => {
          if (refused && stalled(m)) needsProtectedPlayback(refused);
        });
      const onAttempt = (m) => {
        if (attempted.size >= 16) attempted.delete(attempted.values().next().value);
        attempted.add(m);
        judgeAttempt(m);
      };
      const onNeedsKey = (m) =>
        after(KEYS_GRACE_MS, () => {
          if (refused && !m.mediaKeys && !progressed(m)) needsProtectedPlayback(refused);
        });
      const onMediaEvent = guard((e) => {
        const m = e.target;
        if (sent || !(m instanceof HTMLMediaElement)) return;
        if (e.type === "play") onAttempt(m);
        else if (e.type === "encrypted" || e.type === "waitingforkey") onNeedsKey(m);
        else if (e.type === "error" && refused && m.error && m.error.code === MEDIA_ERR_DECODE) needsProtectedPlayback(refused);
      });
      const mediaEvents = ["play", "encrypted", "waitingforkey", "error"];
      for (const type of mediaEvents) document.addEventListener(type, onMediaEvent, true);
      // A media element out of the document is reached through its play().
      const media = HTMLMediaElement.prototype;
      const play = media.play;
      const watched = new WeakSet();
      Object.defineProperty(media, "play", {
        ...Object.getOwnPropertyDescriptor(media, "play"),
        value: {
          play() {
            if (!sent && this instanceof HTMLMediaElement && !this.isConnected && !watched.has(this)) {
              watched.add(this);
              for (const type of mediaEvents) this.addEventListener(type, onMediaEvent);
            }
            return apply(play, this, arguments);
          },
        }.play,
      });
      const onRefused = (keySystem, activated) => {
        if (sent) return;
        if (!refused) refused = keySystem;
        for (const m of attempted) if (stalled(m)) judgeAttempt(m);
        if (activated)
          after(GRACE_MS, () => {
            if (!anyProgressed()) needsProtectedPlayback(keySystem);
          });
      };
      Object.defineProperty(NavigatorType.prototype, "requestMediaKeySystemAccess", {
        ...Object.getOwnPropertyDescriptor(NavigatorType.prototype, "requestMediaKeySystemAccess"),
        value: {
          requestMediaKeySystemAccess(keySystem, configurations) {
            const result = apply(requestAccess, this, arguments);
            if (!sent && typeof keySystem === "string" && apply(test, protectedSystem, [keySystem])) {
              const activated = !!(navigator.userActivation && navigator.userActivation.isActive);
              apply(then, result, [null, guard(() => onRefused(keySystem, activated))]);
            }
            return result;
          },
        }.requestMediaKeySystemAccess,
      });
    })();
    """#
}

extension Engine {
  // The shown Chromium page of a tab reports protected video it cannot play. A site that opens in WebKit (by its
  // rule or the streaming table) switches at once, with a toast to undo it; a site with a Chromium rule, or declined
  // this session, stays; any other gets the offer.
  func webContents(
    _ contents: ECWebContents, didReceiveMessage message: String, fromObject name: String, origin: URL?,
    mainFrame: Bool
  ) {
    guard name == ProtectedMedia.objectName, mainFrame, let tab = shownTab(of: contents),
      let page = owners[ObjectIdentifier(contents)]?.page, let url = contents.url, let origin,
      siteOf(origin) == siteOf(url), engineOffers[tab] == nil
    else { return }
    let site = siteOf(url)
    @Shared(.siteEngines) var siteEngines
    guard !declinedSites.contains(site), siteEngines.rule(for: site) != .chromium else { return }
    if pageEngine(for: url, from: .chromium, choice: nil, cause: .typed, siteEngines) == .webkit {
      offerSwitches[tab] = (site, left: page)
      Self.continuation.yield(.openedInWebKit(tab: tab, site: site))
      Task { await reopen(tab, in: .webkit) }
      return
    }
    let id = UUID()
    engineOffers[tab] = EngineOffer(id: id, tab: tab, page: page, site: site) { [weak self] open, remember in
      self?.answerOffer(id, of: tab, open: open, remember: remember)
    }
  }

  // Open in WebKit switches the tab, Stay in Chromium declines the site for the session; with Remember, either
  // writes the site's rule instead.
  private func answerOffer(_ id: UUID, of tab: UUID, open: Bool, remember: Bool) {
    guard let offer = engineOffers[tab], offer.id == id else { return }
    engineOffers[tab] = nil
    guard let url = page(tab)?.url else { return }
    if remember {
      setEngine(open ? .webkit : .chromium, forSiteOf: url, in: tab)
    } else if open {
      Task { await reopen(tab, in: .webkit) }
    } else {
      declinedSites.insert(offer.site)
    }
  }

  // Undo on "{site} opened in WebKit": the Chromium page the tab left shows again as it was, the WebKit page closes,
  // and the site stays in Chromium for the session. No rule changes.
  func undoEngineSwitch(_ tab: UUID) async {
    guard let switched = offerSwitches.removeValue(forKey: tab) else { return }
    declinedSites.insert(switched.site)
    guard let index = pageRecords[tab]?.firstIndex(where: { $0.id == switched.left }) else { return }
    await syncCookies(tab, showing: index)
    guard let pages = pageRecords[tab], let shown = shownPages[tab],
      let index = pages.firstIndex(where: { $0.id == switched.left }), index == shown - 1, pages[shown].engine == .webkit
    else { return }
    choices[tab] = EngineChoice(engine: .chromium, site: switched.site)
    show(tab, index)
    closePage(pages[shown].id, of: tab)
  }

  // Leaving the page that made the tab's offer withdraws it: a navigation committed in it, or the tab showing
  // another page.
  func withdrawOffer(_ tab: UUID, committedIn page: UUID?) {
    guard let offer = engineOffers[tab], page == offer.page || shownRecord(tab)?.id != offer.page else { return }
    engineOffers[tab] = nil
  }
}
