import Foundation

// Settings > Advanced > Export Data: a Markdown file listing each space's favorites, pinned tabs, folders
// and Today tabs.
enum ExportData {
  static func markdown(_ spaces: [Space]) -> String {
    var lines = ["# Spaces", ""]
    for space in spaces {
      lines.append("## \(space.name)")
      lines.append("")
      let favorites = space.favoriteGrid.joined()
      if !favorites.isEmpty {
        lines.append("### Favorites")
        lines.append("")
        lines += favorites.map { line($0, depth: 0) }
        lines.append("")
      }
      let pinned = space.rows(in: .pinned)
      if !pinned.isEmpty {
        lines.append("### Pinned")
        lines.append("")
        lines += pinned.flatMap { rowLines($0, in: space, depth: 0) }
        lines.append("")
      }
      let today = space.tabs(in: .unpinned)
      if !today.isEmpty {
        lines.append("### Today")
        lines.append("")
        lines += today.map { line($0, depth: 0) }
        lines.append("")
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func rowLines(_ row: PinnedRow, in space: Space, depth: Int) -> [String] {
    switch row {
    case let .tab(tab):
      return [line(tab, depth: depth)]
    case let .folder(folder):
      return [String(repeating: "  ", count: depth) + "- **\(folder.name)**"]
        + space.rows(in: .folder(folder.id)).flatMap { rowLines($0, in: space, depth: depth + 1) }
    }
  }

  // Brackets and backslashes in a title are escaped and the URL is in angle brackets, so the link always parses.
  private static func line(_ tab: Tab, depth: Int) -> String {
    let url = (tab.pinnedURL ?? tab.url).absoluteString
    let title = (tab.displayTitle.isEmpty ? url : tab.displayTitle)
      .replacing("\\", with: "\\\\").replacing("[", with: "\\[").replacing("]", with: "\\]")
    return String(repeating: "  ", count: depth) + "- [\(title)](<\(url)>)"
  }
}
