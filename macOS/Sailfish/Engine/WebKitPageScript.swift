// Copyright 2026 Mantra Patel. Licensed under the Apache License 2.0.
// Adapted from Ardia's packages/ardiacore/ios/WebKitPageScript.swift at a01a909; Sailfish changed it.

import Foundation
import WebKit

// The scripts every WebKit page runs at document start in all frames: `isolated` in Sailfish's own content world,
// posting to the `sailfish` message handler, and `pageWorld` in the page's world, where it captures the page's
// Media Session handlers and hands them to the isolated script through DOM events.
enum WebKitPageScript {
  @MainActor static let world = WKContentWorld.world(name: "Sailfish")

  static let isolated = #"""
(() => {
  if (window.__sailfish) return;
  const isTop = window === window.top;
  const frame = Math.random().toString(36).slice(2);
  const post = (kind, data) => {
    try {
      window.webkit.messageHandlers.sailfish.postMessage({ kind, data: data === undefined ? null : data, frame });
    } catch (e) {}
  };
  let muted = false;
  const mutedByUs = new WeakSet();
  const mediaEvents = ["play", "playing", "pause", "ended", "volumechange", "emptied", "loadedmetadata", "seeked", "ratechange"];
  const detached = new Set();
  const listened = new WeakSet();
  const heard = new WeakSet();
  let lastMedia = null;
  let lastHeard = null;
  let pageActions = [];
  let pagePosition = null;
  const allMedia = () => {
    const list = Array.from(document.querySelectorAll("video, audio"));
    for (const m of detached) if (!list.includes(m)) list.push(m);
    return list;
  };
  const playing = (m) => !m.paused && !m.ended;
  const audible = (m) => playing(m) && !m.muted && m.volume > 0;
  // Media the tab's mute silences still counts as sound, as a muted Chromium tab stays audible.
  const sounding = (m) => playing(m) && (!m.muted || mutedByUs.has(m)) && m.volume > 0;
  const applyMute = (m) => {
    if (muted && !m.muted) {
      m.muted = true;
      mutedByUs.add(m);
    }
  };
  const active = (list) => {
    const present = (m) => (m && list.includes(m) ? m : null);
    return list.find((m) => heard.has(m) && playing(m)) || present(lastHeard) || list.find(playing) || present(lastMedia);
  };
  const sessionState = () => (navigator.mediaSession ? navigator.mediaSession.playbackState : "none");
  const advancePosition = (state) => {
    const playingNow = state === "playing";
    if (playingNow === pagePosition.playing) return;
    const now = Date.now();
    if (pagePosition.playing) pagePosition.position += ((now - pagePosition.at) / 1000) * pagePosition.playbackRate;
    pagePosition.at = now;
    pagePosition.playing = playingNow;
  };
  const positionOf = (m, state) => {
    if (!pagePosition) return isFinite(m.currentTime) ? m.currentTime : 0;
    advancePosition(state);
    const { position, duration, playbackRate, at, playing } = pagePosition;
    const now = position + (playing ? ((Date.now() - at) / 1000) * playbackRate : 0);
    return Math.max(0, duration > 0 ? Math.min(now, duration) : now);
  };
  const movePagePosition = (m, state, to) => {
    if (!pagePosition) return;
    positionOf(m, state);
    pagePosition.position = Math.max(0, pagePosition.duration > 0 ? Math.min(to, pagePosition.duration) : to);
    pagePosition.at = Date.now();
  };
  let queued = false;
  let reported = false;
  const report = () => {
    queued = false;
    reported = true;
    const list = allMedia();
    post("media", { audible: list.some(sounding), muted });
    const m = active(list);
    const session = navigator.mediaSession;
    const fromSession = sessionState();
    if (!m || (m.paused && !m.currentTime && fromSession === "none")) return post("nowPlaying", null);
    const meta = session && session.metadata;
    const art = meta && meta.artwork && meta.artwork.length ? meta.artwork[meta.artwork.length - 1].src : null;
    const state = fromSession !== "none" ? fromSession : playing(m) ? "playing" : "paused";
    const duration = pagePosition && pagePosition.duration > 0 ? pagePosition.duration : m.duration;
    post("nowPlaying", {
      title: (meta && meta.title) || document.title || "",
      artist: (meta && meta.artist) || "",
      album: (meta && meta.album) || "",
      artwork: art,
      playbackState: state,
      position: positionOf(m, state),
      duration: isFinite(duration) ? duration : null,
      playbackRate: pagePosition ? pagePosition.playbackRate : m.playbackRate || 1,
      timestamp: Date.now(),
      hasVideo: m.tagName === "VIDEO" && m.videoWidth > 0,
      actions: pageActions,
      controllable: fromSession !== "none" || !(m.duration > 0 && m.duration <= 5),
    });
  };
  const schedule = () => {
    if (queued) return;
    queued = true;
    setTimeout(report, 100);
  };
  const listen = (m) => {
    if (listened.has(m)) return;
    listened.add(m);
    for (const type of mediaEvents) m.addEventListener(type, onMedia);
  };
  const track = (m) => {
    listen(m);
    if (detached.has(m)) return;
    if (detached.size >= 8) for (const old of detached) if (!playing(old)) {
      detached.delete(old);
      break;
    }
    detached.add(m);
  };
  const onMedia = (e) => {
    const m = e.target;
    if (!(m instanceof HTMLMediaElement)) return;
    if (!m.isConnected) track(m);
    lastMedia = m;
    if (e.type === "play" || e.type === "playing") {
      applyMute(m);
      listen(m);
    }
    if (e.type === "volumechange") applyMute(m);
    if (audible(m)) {
      heard.add(m);
      lastHeard = m;
    }
    schedule();
  };
  for (const type of mediaEvents) document.addEventListener(type, onMedia, true);
  document.addEventListener(
    "sailfish:media-element",
    (e) => {
      const m = e.relatedTarget;
      if (!(m instanceof HTMLMediaElement)) return;
      track(m);
      schedule();
    },
    true,
  );
  const knownActions = ["play", "pause", "stop", "seekbackward", "seekforward", "seekto", "previoustrack", "nexttrack", "skipad", "enterpictureinpicture"];
  document.addEventListener(
    "sailfish:media-session",
    (e) => {
      let data = null;
      try {
        data = typeof e.detail === "string" ? JSON.parse(e.detail) : null;
      } catch (error) {}
      if (!data || typeof data !== "object") return;
      pageActions = Array.isArray(data.actions) ? knownActions.filter((a) => data.actions.includes(a)) : [];
      const p = data.position;
      const finite = (n) => typeof n === "number" && isFinite(n);
      if (!p || !finite(p.position) || !finite(p.duration)) pagePosition = null;
      else {
        const sample = finite(p.id) ? p.id : null;
        if (!pagePosition || sample === null || pagePosition.sample !== sample)
          pagePosition = {
            position: Math.max(0, p.position),
            duration: p.duration,
            playbackRate: finite(p.playbackRate) && p.playbackRate ? p.playbackRate : 1,
            at: finite(p.at) ? p.at : Date.now(),
            sample,
            playing: p.playing === true,
          };
      }
      schedule();
    },
    true,
  );
  // A document that reported media takes it with it when it goes; one restored from the back-forward cache reports
  // again.
  addEventListener("pagehide", () => reported && post("media", null));
  addEventListener("pageshow", (e) => e.persisted && schedule());
  const pip = (on) => post("pip", { active: on });
  document.addEventListener("enterpictureinpicture", () => pip(true), true);
  document.addEventListener("leavepictureinpicture", () => pip(false), true);
  document.addEventListener(
    "webkitpresentationmodechanged",
    (e) => e.target instanceof HTMLVideoElement && pip(e.target.webkitPresentationMode === "picture-in-picture"),
    true,
  );

  let hovered = "";
  const hover = (href) => {
    if (href === hovered) return;
    hovered = href;
    post("hover", href);
  };
  document.addEventListener(
    "mouseover",
    (e) => {
      const link = e.target && e.target.closest ? e.target.closest("a[href]") : null;
      hover(link ? link.href : "");
    },
    true,
  );
  document.addEventListener("mouseout", (e) => e.relatedTarget || hover(""), true);

  // What a right click is on, for Sailfish's context menu, which opens right after.
  const textTypes = ["text", "search", "url", "tel", "email", "password", "number"];
  document.addEventListener(
    "contextmenu",
    (e) => {
      const target = e.target instanceof Element ? e.target : null;
      const link = target && target.closest("a[href], area[href]");
      const image = target && target.closest("img");
      const isField =
        !!target && (target.tagName === "TEXTAREA" || (target.tagName === "INPUT" && textTypes.includes(target.type)));
      const field = isField && !target.readOnly && !target.disabled ? target : null;
      const editable = !!field || !!(target && target.isContentEditable);
      // A text field's selection is not the document's.
      const selection = field
        ? field.value.substring(field.selectionStart || 0, field.selectionEnd || 0)
        : String(getSelection() || "");
      post("contextMenu", {
        link: link && typeof link.href === "string" ? link.href : "",
        linkText: link ? link.innerText.trim() : "",
        image: image ? image.currentSrc || image.src : "",
        selection,
        editable,
        direction: editable ? getComputedStyle(target).direction : "",
      });
    },
    true,
  );

  if (isTop) {
    // The page's first content, or for a page that shows none, two frames after its load.
    new PerformanceObserver((list, observer) => {
      if (!list.getEntriesByName("first-contentful-paint").length) return;
      observer.disconnect();
      post("painted");
    }).observe({ type: "paint", buffered: true });
    addEventListener("load", () => requestAnimationFrame(() => requestAnimationFrame(() => post("painted"))), {
      once: true,
    });

    let selected = "";
    let pending = false;
    document.addEventListener("selectionchange", () => {
      if (pending) return;
      pending = true;
      setTimeout(() => {
        pending = false;
        const text = String(getSelection() || "");
        if (text === selected) return;
        selected = text;
        post("selection", text);
      }, 100);
    });

    const largest = (link) => {
      const sizes = (link.getAttribute("sizes") || "").toLowerCase().split(/\s+/).filter((s) => /^\d+x\d+$/.test(s));
      return sizes.length ? Math.max(...sizes.map((s) => parseInt(s, 10))) : 0;
    };
    const rank = (size) => (size >= 32 ? [0, size] : size === 0 ? [1, 0] : [2, -size]);
    const sendIcons = () => {
      const icons = Array.from(document.querySelectorAll('link[rel~="icon" i]'))
        .filter((l) => /^(https?|data):/.test(l.href))
        .map((l) => ({ href: l.href, rank: rank(largest(l)) }))
        .filter((i) => i.rank[0] < 2 || -i.rank[1] >= 16)
        .sort((a, b) => a.rank[0] - b.rank[0] || a.rank[1] - b.rank[1])
        .map((i) => i.href);
      if (!icons.length && /^https?:$/.test(location.protocol)) icons.push(location.origin + "/favicon.ico");
      if (icons.length) post("icons", icons);
    };
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", sendIcons, { once: true });
    else sendIcons();
    addEventListener("load", sendIcons, { once: true });
  }

  // Find in page, marked as Chromium marks it: every match yellow and the active one orange, through the CSS Custom
  // Highlight API and a style sheet that stays out of the page's DOM. Matches follow the rendered text of the main
  // frame: case ignored, accents ignored unless the string has some, whitespace collapsed, and text joined across
  // inline elements but not across blocks.
  const marks = { text: "", ranges: [], active: -1 };
  const markSheet = new CSSStyleSheet();
  markSheet.replaceSync(
    "::highlight(sailfish-match) { background-color: #ffff00; color: #000000 } ::highlight(sailfish-active) { background-color: #ff9632; color: #000000 }"
  );
  // A highlight's ranges are cleared before it leaves the registry, since WebKit repaints for the first and not the
  // second.
  const unmark = () => {
    for (const name of ["sailfish-match", "sailfish-active"]) {
      const highlight = CSS.highlights.get(name);
      if (highlight) highlight.clear();
      CSS.highlights.delete(name);
    }
    if (document.adoptedStyleSheets.includes(markSheet)) document.adoptedStyleSheets = document.adoptedStyleSheets.filter((s) => s !== markSheet);
    marks.text = "";
    marks.ranges = [];
    marks.active = -1;
  };
  const folds = [new Map(), new Map()];
  // A character as matching compares it: lowercase, whitespace as a space, and without its accent when `accents` is
  // false, where a lone combining mark folds to nothing.
  const fold = (c, accents) => {
    const code = c.charCodeAt(0);
    if (code < 128) return code === 32 || (code >= 9 && code <= 13) ? " " : code >= 65 && code <= 90 ? String.fromCharCode(code + 32) : c;
    const cache = folds[accents ? 1 : 0];
    let f = cache.get(c);
    if (f === undefined) {
      f = /\s/.test(c) ? " " : c.toLowerCase();
      if (!accents && f !== " ") f = f.normalize("NFD").replace(/\p{M}/gu, "");
      if (f.length > 1) f = c;
      cache.set(c, f);
    }
    return f;
  };
  const matchRanges = (text) => {
    const accents = /\p{M}/u.test(text.normalize("NFD"));
    const needle = text.split("").map((c) => fold(c, accents)).join("").replace(/ +/g, " ");
    if (!needle || !document.body) return [];
    const shown = new Map();
    const inlines = new Map();
    const inline = (el) => {
      let yes = inlines.get(el);
      if (yes === undefined) inlines.set(el, (yes = /^(inline|contents)/.test(getComputedStyle(el).display)));
      return yes;
    };
    const sibling = (n, key) => {
      do n = n[key];
      while (n && n.nodeType === Node.COMMENT_NODE);
      return n;
    };
    // Whether only inline elements separate text node `a` from the next one, `b`.
    const joined = (a, b) => {
      let x = a;
      while (!x.parentNode.contains(b)) {
        if (sibling(x, "nextSibling")) return false;
        x = x.parentNode;
        if (!inline(x)) return false;
      }
      let y = b;
      while (y.parentNode !== x.parentNode) {
        if (sibling(y, "previousSibling")) return false;
        y = y.parentNode;
        if (!inline(y)) return false;
      }
      return sibling(x, "nextSibling") === y;
    };
    const chars = [];
    const nodes = [];
    const offsets = [];
    let previous = null;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const parent = n.parentElement;
      let visible = shown.get(parent);
      if (visible === undefined) shown.set(parent, (visible = parent.tagName !== "TEXTAREA" && parent.checkVisibility({ visibilityProperty: true })));
      if (!visible) continue;
      if (previous && !joined(previous, n)) {
        chars.push("\n");
        nodes.push(null);
        offsets.push(0);
      }
      previous = n;
      const data = n.data;
      for (let i = 0; i < data.length; i++) {
        const c = fold(data[i], accents);
        const last = chars[chars.length - 1];
        if (!c || (c === " " && (last === undefined || last === " " || last === "\n"))) continue;
        chars.push(c);
        nodes.push(n);
        offsets.push(i);
      }
    }
    const haystack = chars.join("");
    const ranges = [];
    for (let at = haystack.indexOf(needle); at >= 0; at = haystack.indexOf(needle, at + needle.length)) {
      const end = at + needle.length - 1;
      const range = new Range();
      range.setStart(nodes[at], offsets[at]);
      range.setEnd(nodes[end], offsets[end] + 1);
      ranges.push(range);
    }
    return ranges;
  };
  // How far a scroller moves to show the span from `start` to `end` in its box from `from` to `to`, as Chromium
  // reveals its active match: not at all when the span shows, to the nearer edge when part of it does, and to the
  // middle when none does.
  const offset = (start, end, from, to) =>
    start >= from && end <= to ? 0 : end <= from || start >= to ? (start + end - from - to) / 2 : start < from ? start - from : end - to;
  // Scrolls every scroller the range is in to show it, the page last.
  const reveal = (range) => {
    for (let el = range.startContainer.parentElement; el; el = el.parentElement) {
      const page = el === document.scrollingElement;
      if (!page && (el.scrollHeight <= el.clientHeight && el.scrollWidth <= el.clientWidth || !/auto|scroll|overlay/.test(getComputedStyle(el).overflow))) continue;
      const box = page ? { top: 0, left: 0, bottom: innerHeight, right: innerWidth } : el.getBoundingClientRect();
      const r = range.getBoundingClientRect();
      const top = offset(r.top, r.bottom, box.top, box.bottom);
      const left = offset(r.left, r.right, box.left, box.right);
      if (top || left) (page ? window : el).scrollBy({ top, left, behavior: "instant" });
    }
  };

  window.__sailfish = {
    mute(on) {
      muted = !!on;
      for (const m of allMedia()) {
        if (muted) applyMute(m);
        else if (mutedByUs.has(m)) {
          m.muted = false;
          mutedByUs.delete(m);
        }
      }
      report();
    },
    media(action, seconds) {
      const m = active(allMedia());
      const call = (name, details) =>
        pageActions.includes(name) &&
        !document.dispatchEvent(new CustomEvent("sailfish:media-action", { cancelable: true, detail: JSON.stringify({ action: name, ...details }) }));
      const isPlaying = sessionState() === "playing" || (!!m && playing(m));
      if (action === "play") call("play") || (m && m.play());
      else if (action === "pause") call("pause") || (m && m.pause());
      else if (action === "stop") call("stop") || (m && m.pause());
      else if (action === "toggle") isPlaying ? call("pause") || (m && m.pause()) : call("play") || (m && m.play());
      else if (action === "next") call("nexttrack");
      else if (action === "previous") call("previoustrack");
      else if (action === "seekBy") {
        const handled = seconds >= 0 ? call("seekforward", { seekOffset: seconds }) : call("seekbackward", { seekOffset: -seconds });
        if (!handled && m) {
          const state = isPlaying ? "playing" : "paused";
          const from = pagePosition ? positionOf(m, state) : m.currentTime;
          m.currentTime = Math.max(0, Math.min(m.duration || Infinity, m.currentTime + seconds));
          movePagePosition(m, state, from + seconds);
        }
      } else if (action === "seekTo" && !call("seekto", { seekTime: seconds }) && m) {
        m.currentTime = Math.max(0, seconds);
        movePagePosition(m, isPlaying ? "playing" : "paused", seconds);
      }
      schedule();
      return !!m || pageActions.length > 0;
    },
    pictureInPicture(on) {
      if (!on) {
        if (document.pictureInPictureElement) document.exitPictureInPicture();
        for (const v of document.querySelectorAll("video")) if (v.webkitPresentationMode === "picture-in-picture") v.webkitSetPresentationMode("inline");
        return true;
      }
      const videos = Array.from(document.querySelectorAll("video"));
      const v = videos.find((x) => !x.paused) || videos.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
      if (!v) return false;
      if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode("picture-in-picture")) v.webkitSetPresentationMode("picture-in-picture");
      else if (v.requestPictureInPicture) v.requestPictureInPicture();
      else return false;
      return true;
    },
    // A new `text` starts at its first match, or its last when `step` is negative; the same text moves the active
    // match by `step`. Answers the match count, the active match from 1, and for a new text each match's place down
    // the page from 0 to 1 for the scrollbar's ticks, empty when the page does not scroll.
    find(text, step) {
      let ticks = null;
      if (text !== marks.text || !text) {
        unmark();
        getSelection().removeAllRanges();
        const found = matchRanges(text).map((range) => [range, range.getBoundingClientRect()]).filter(([, r]) => r.width || r.height);
        marks.text = text;
        marks.ranges = found.map(([range]) => range);
        marks.active = found.length ? (step < 0 ? found.length - 1 : 0) : -1;
        const page = document.scrollingElement;
        ticks = page && page.scrollHeight > page.clientHeight ? found.map(([, r]) => Math.floor(r.top + scrollY) / page.scrollHeight) : [];
        if (found.length) {
          const all = new Highlight();
          for (const range of marks.ranges) all.add(range);
          CSS.highlights.set("sailfish-match", all);
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, markSheet];
        }
      } else if (step && marks.ranges.length) {
        marks.active = (marks.active + step + marks.ranges.length) % marks.ranges.length;
      }
      const range = marks.ranges[marks.active];
      if (range) {
        const all = CSS.highlights.get("sailfish-match");
        const previous = CSS.highlights.get("sailfish-active");
        if (previous) for (const r of previous) all.add(r);
        all.delete(range);
        CSS.highlights.set("sailfish-active", new Highlight(range));
        if (ticks || step) reveal(range);
      }
      return [marks.ranges.length, marks.active + 1, ticks];
    },
    // Clears the marks and keeps the active match selected, as Chromium does when its find bar closes.
    stopFinding() {
      const range = marks.ranges[marks.active];
      unmark();
      if (range) getSelection().setBaseAndExtent(range.startContainer, range.startOffset, range.endContainer, range.endOffset);
    },
  };
})();
"""#

  static let pageWorld = #"""
(() => {
  const apply = Reflect.apply;
  const dispatch = EventTarget.prototype.dispatchEvent;
  const listen = EventTarget.prototype.addEventListener;
  const preventDefault = Event.prototype.preventDefault;
  const detailOf = Object.getOwnPropertyDescriptor(CustomEvent.prototype, "detail").get;
  const connected = Object.getOwnPropertyDescriptor(Node.prototype, "isConnected").get;
  const { stringify, parse } = JSON;
  const Custom = CustomEvent;
  const Mouse = MouseEvent;
  const now = Date.now;
  const doc = document;
  const handedOver = new WeakSet();
  const mediaProto = HTMLMediaElement.prototype;
  const play = mediaProto.play;
  mediaProto.play = function () {
    if (!handedOver.has(this) && !apply(connected, this, [])) {
      handedOver.add(this);
      try {
        apply(dispatch, doc, [new Mouse("sailfish:media-element", { relatedTarget: this })]);
      } catch (e) {}
    }
    return apply(play, this, arguments);
  };

  const session = navigator.mediaSession;
  const proto = session && Object.getPrototypeOf(session);
  if (!proto) return;
  const handlers = new Map();
  let position = null;
  let samples = 0;
  const notify = () => {
    try {
      apply(dispatch, doc, [new Custom("sailfish:media-session", { detail: stringify({ actions: Array.from(handlers.keys()), position }) })]);
    } catch (e) {}
  };
  const setActionHandler = proto.setActionHandler;
  if (typeof setActionHandler === "function") {
    proto.setActionHandler = function (action, handler) {
      const result = apply(setActionHandler, this, arguments);
      if (typeof handler === "function") handlers.set(String(action), handler);
      else handlers.delete(String(action));
      notify();
      return result;
    };
  }
  const setPositionState = proto.setPositionState;
  if (typeof setPositionState === "function") {
    proto.setPositionState = function (state) {
      const result = apply(setPositionState, this, arguments);
      position =
        state && typeof state === "object"
          ? { duration: +state.duration, position: +(state.position || 0), playbackRate: +(state.playbackRate || 1), at: now(), id: ++samples, playing: this.playbackState === "playing" }
          : null;
      notify();
      return result;
    };
  }
  for (const name of ["metadata", "playbackState"]) {
    const d = Object.getOwnPropertyDescriptor(proto, name);
    if (!d || !d.set) continue;
    Object.defineProperty(proto, name, {
      ...d,
      set(value) {
        apply(d.set, this, [value]);
        notify();
      },
    });
  }
  apply(listen, doc, [
    "sailfish:media-action",
    (e) => {
      let request = null;
      try {
        request = parse(apply(detailOf, e, []));
      } catch (error) {}
      const handler = request && typeof request.action === "string" ? handlers.get(request.action) : null;
      if (typeof handler !== "function") return;
      apply(preventDefault, e, []);
      const details = { action: request.action };
      if (typeof request.seekOffset === "number") details.seekOffset = request.seekOffset;
      if (typeof request.seekTime === "number") details.seekTime = request.seekTime;
      try {
        handler(details);
      } catch (error) {}
    },
    true,
  ]);
})();
"""#
}

// A message from the isolated script. Its body is a dictionary of `kind`, `data` and the posting frame's id.
enum PageScriptMessage {
  // The link under the pointer, nil when it leaves the link.
  case hover(URL?)
  // The main frame's selected text, empty when nothing is selected.
  case selection(String)
  // The main frame's icons, best first.
  case icons([URL])
  // The main frame painted its first content.
  case painted
  // What a right click in any frame is on.
  case contextMenu(WebKitContextMenu.Hit)
  // A report on a frame's media, from any frame, with the id the frame's script gave itself.
  case media(frame: String, MediaReport)

  init?(_ body: Any) {
    guard let body = body as? [String: Any], let kind = body["kind"] as? String else { return nil }
    switch (kind, body["data"]) {
    case let ("hover", href as String): self = .hover(URL(string: href))
    case let ("selection", text as String): self = .selection(text)
    case let ("icons", hrefs as [String]): self = .icons(hrefs.compactMap { URL(string: $0) })
    case ("painted", _): self = .painted
    case let ("contextMenu", hit as [String: Any]): self = .contextMenu(WebKitContextMenu.Hit(hit))
    case let (kind, data):
      guard let frame = body["frame"] as? String, let report = MediaReport(kind, data) else { return nil }
      self = .media(frame: frame, report)
    }
  }
}
