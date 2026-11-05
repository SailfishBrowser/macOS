import Foundation

// A tab whose page waits on the user stays awake: an open dialog, permission request or sheet, typed text not yet
// sent, or a stream playing in a media element, as a call's is while nobody speaks.
extension Engine {
  func canSleep(_ tab: UUID) async -> Bool {
    let pages = pageRecords[tab] ?? []
    guard dialogs[tab] == nil, permissionRequests[tab] == nil, sheets[tab]?.isEmpty ?? true,
      !pages.contains(where: { pendingSheets[$0.id] != nil })
    else { return false }
    guard let page = page(tab) else { return true }
    // A page that has not answered in two seconds, hung or busy, counts as waiting and stays awake; a late answer
    // is dropped.
    return await withCheckedContinuation { continuation in
      let answer = SleepAnswer(continuation)
      page.evaluateJavaScript(Self.waitingScript) { answer.give($0 != "true") }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        MainActor.assumeIsolated { answer.give(false) }
      }
    }
  }

  // Searches the document, its same-site frames and the shadow roots it can see; another site's frame is out of a
  // page script's reach, and so is a closed root on Chromium, so a focused custom element with no visible root counts
  // as waiting.
  static let waitingScript = """
    (() => {
      const skipped = new Set(['hidden', 'submit', 'button', 'reset', 'image']);
      const changed = (field) => {
        if (field.tagName === 'SELECT') return [...field.options].some((o) => o.selected !== o.defaultSelected);
        if (field.tagName === 'TEXTAREA') return field.value !== field.defaultValue;
        if (skipped.has(field.type)) return false;
        if (field.type === 'checkbox' || field.type === 'radio') return field.checked !== field.defaultChecked;
        return field.value !== field.defaultValue;
      };
      const waits = (root) => {
        const active = root.activeElement;
        return [...root.querySelectorAll('input, textarea, select')].some(changed)
          || (!!active && active.isContentEditable && active.textContent.trim() !== '')
          || (!!active && active.tagName.includes('-') && !active.shadowRoot)
          || [...root.querySelectorAll('audio, video')].some((m) => m.srcObject && !m.paused)
          || [...root.querySelectorAll('iframe')].some((f) => f.contentDocument && waits(f.contentDocument))
          || [...root.querySelectorAll('*')].some((el) => el.shadowRoot && waits(el.shadowRoot));
      };
      return String(waits(document));
    })()
    """
}

// The first of a page's answer and the time limit resumes the check.
@MainActor private final class SleepAnswer {
  private var continuation: CheckedContinuation<Bool, Never>?

  init(_ continuation: CheckedContinuation<Bool, Never>) {
    self.continuation = continuation
  }

  func give(_ canSleep: Bool) {
    continuation?.resume(returning: canSleep)
    continuation = nil
  }
}
