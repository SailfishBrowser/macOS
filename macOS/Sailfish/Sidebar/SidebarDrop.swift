import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Drops onto the sidebar: a link opens in a new tab, dropped text becomes a search for it (or the address it
// is), and files from the Finder open as file tabs. Each lands at the top of Today. The items are read from the
// drag pasteboard, which holds them for the drop.
private struct SidebarDrop: ViewModifier {
  @Binding var isTargeted: Bool
  let open: ([URL]) -> Void

  func body(content: Content) -> some View {
    content.onDrop(of: [.fileURL, .url, .plainText], isTargeted: $isTargeted) { _ in
      let board = NSPasteboard(name: .drag)
      if let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
        open(urls)
      } else if let strings = board.readObjects(forClasses: [NSString.self]) as? [String] {
        let texts = strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        open(texts.map(URL.pasted))
      }
      return true
    }
  }
}

extension View {
  func sidebarDrop(isTargeted: Binding<Bool>, open: @escaping ([URL]) -> Void) -> some View {
    modifier(SidebarDrop(isTargeted: isTargeted, open: open))
  }
}
