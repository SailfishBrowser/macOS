import AppKit
@preconcurrency import EngineCore

// The menu bar's items for the selected tab's page.
extension WindowController {
  private func page(_ operation: (ECWebContents) -> Void) {
    store.spaces.selected.selectedTabID.map { Engine.shared.perform($0, operation) }
  }

  @objc func zoomIn(_ sender: Any?) {
    store.send(.zoom(.in))
  }

  @objc func zoomOut(_ sender: Any?) {
    store.send(.zoom(.out))
  }

  @objc func resetZoom(_ sender: Any?) {
    store.send(.zoom(.reset))
  }

  // Edit > Find > Jump to Selection (⌘J): scrolls the selection, or the active find match, into view.
  @objc func jumpToSelection(_ sender: Any?) {
    page { $0.scrollSelectionIntoView() }
  }

  @objc func toggleReader(_ sender: Any?) {
    store.spaces.selected.selectedTabID.map(Engine.shared.toggleReader)
  }

  @objc func savePage(_ sender: Any?) {
    page { $0.savePage() }
  }

  @objc func printPage(_ sender: Any?) {
    page { $0.print() }
  }

  @objc func copyURLAsMarkdown(_ sender: Any?) {
    guard let tab = store.spaces.selected.selectedTab else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("[\(tab.displayTitle)](\(tab.url.absoluteString))", forType: .string)
    store.send(.showToast("Copied Current URL"))
  }

  // Copy URL as Quote: the selected text and a link that scrolls to and highlights it.
  @objc func copyURLAsQuote(_ sender: Any?) {
    guard let tab = store.spaces.selected.selectedTabID, let quote = Engine.shared.selections[tab] else { return }
    page { contents in
      contents.linkToHighlight { link in
        guard let link else { return }
        MainActor.assumeIsolated {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString("“\(quote)”\n\(link.absoluteString)", forType: .string)
          self.store.send(.showToast("Copied Current URL"))
        }
      }
    }
  }

  // Copies the visible page as an image, as the site controls' Capture does.
  @objc func capture(_ sender: Any?) {
    let space = store.spaces.selected
    guard let tab = space.selectedTab else { return }
    page { contents in
      contents.snapshot { image in
        guard let image else { return }
        MainActor.assumeIsolated { Captures.keep(image, of: tab, in: space) }
        SoundEffect.play(.capture)
      }
    }
  }

  @objc func showJavaScriptConsole(_ sender: Any?) {
    page { $0.showConsole() }
  }

  @objc func inspectElements(_ sender: Any?) {
    page { $0.inspectElement() }
  }

  // Chrome's page source, in a new tab.
  @objc func viewSource(_ sender: Any?) {
    guard let url = store.spaces.selected.selectedTab?.url else { return }
    store.send(.tab(.open(URL(string: "view-source:" + url.absoluteString)!), in: store.spaces.selectedID))
  }

  // Opens the history page in a new tab.
  @objc func viewHistory(_ sender: Any?) {
    store.send(.tab(.open(URL(string: "chrome://history/")!), in: store.spaces.selectedID))
  }

  // The command bar's Manage Passwords: the profile's password manager in a tab.
  @objc func managePasswords(_ sender: Any?) {
    store.send(.tab(.open(URL(string: "chrome://password-manager/passwords")!), in: store.spaces.selectedID))
  }
}
