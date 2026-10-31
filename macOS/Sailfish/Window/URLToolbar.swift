import SwiftUI

// Show as Toolbar: the page's address, centered in a thin strip across the top of the card, for a lone page.
// Split panes and developer pages have their own bars. Clicking the address edits it, as ⌘L does.
struct URLToolbar: View {
  static let height = 32.0
  let url: URL
  let edit: () -> Void

  var body: some View {
    Button(action: edit) {
      Text(url.absoluteString)
        .font(.system(size: 12))
        .foregroundStyle(Theme.pillText)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(height: Self.height)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Theme.hover).frame(height: 1)
    }
  }
}
