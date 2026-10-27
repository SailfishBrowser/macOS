import SwiftUI

// The folder glyph: a folder outlined in the accent over a light fill, open while expanded and closed when
// collapsed. It swaps in one frame while the rows below move.
struct FolderGlyph: View {
  let isOpen: Bool
  let accent: Color

  var body: some View {
    if isOpen {
      ZStack {
        OpenFolder(part: .back).fill(.white.opacity(0.85))
        OpenFolder(part: .back).stroke(accent, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        OpenFolder(part: .front).fill(.white.opacity(0.95))
        OpenFolder(part: .front).stroke(accent, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
      }
      .frame(width: 19, height: 15)
      .transition(.identity)
    } else {
      ZStack {
        ClosedFolder().fill(.white.opacity(0.9))
        ClosedFolder().stroke(accent, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
      }
      .frame(width: 19, height: 15)
      .transition(.identity)
    }
  }
}

// A closed folder: its tab at the top left over a rounded body.
private struct ClosedFolder: Shape {
  func path(in rect: CGRect) -> Path {
    let w = rect.width, h = rect.height
    var path = Path()
    path.move(to: CGPoint(x: 1, y: h - 2.5))
    path.addLine(to: CGPoint(x: 1, y: 2.5))
    path.addQuadCurve(to: CGPoint(x: 2.5, y: 1), control: CGPoint(x: 1, y: 1))
    path.addLine(to: CGPoint(x: w * 0.32, y: 1))
    path.addLine(to: CGPoint(x: w * 0.42, y: 3))
    path.addLine(to: CGPoint(x: w - 2.5, y: 3))
    path.addQuadCurve(to: CGPoint(x: w - 1, y: 4.5), control: CGPoint(x: w - 1, y: 3))
    path.addLine(to: CGPoint(x: w - 1, y: h - 2.5))
    path.addQuadCurve(to: CGPoint(x: w - 2.5, y: h - 1), control: CGPoint(x: w - 1, y: h - 1))
    path.addLine(to: CGPoint(x: 2.5, y: h - 1))
    path.addQuadCurve(to: CGPoint(x: 1, y: h - 2.5), control: CGPoint(x: 1, y: h - 1))
    path.closeSubpath()
    // The body's top edge below the tab.
    path.move(to: CGPoint(x: 1, y: 5.5))
    path.addLine(to: CGPoint(x: w - 1, y: 5.5))
    return path
  }
}

private struct OpenFolder: Shape {
  enum Part { case back, front }
  let part: Part

  func path(in rect: CGRect) -> Path {
    let w = rect.width, h = rect.height
    var path = Path()
    switch part {
    case .back:
      // The folder's back with its tab, top left.
      path.move(to: CGPoint(x: 1, y: h - 1))
      path.addLine(to: CGPoint(x: 1, y: 2.5))
      path.addQuadCurve(to: CGPoint(x: 2.5, y: 1), control: CGPoint(x: 1, y: 1))
      path.addLine(to: CGPoint(x: w * 0.3, y: 1))
      path.addLine(to: CGPoint(x: w * 0.4, y: 3))
      path.addLine(to: CGPoint(x: w * 0.78, y: 3))
      path.addQuadCurve(to: CGPoint(x: w * 0.84, y: 4.5), control: CGPoint(x: w * 0.84, y: 3))
      path.addLine(to: CGPoint(x: w * 0.84, y: h * 0.42))
    case .front:
      // The front flap, tipped forward.
      path.move(to: CGPoint(x: w * 0.2, y: h * 0.42))
      path.addLine(to: CGPoint(x: w - 1, y: h * 0.42))
      path.addLine(to: CGPoint(x: w * 0.82, y: h - 1))
      path.addLine(to: CGPoint(x: 1, y: h - 1))
      path.closeSubpath()
    }
    return path
  }
}

// The "Search <folder>..." popover: the folder's tabs, filtered as you type, the first match marked; Enter
// opens the marked one and the arrow keys move the mark.
struct FolderSearch: View {
  let folder: Folder
  let tabs: [Tab]
  let select: (Tab.ID) -> Void
  @State private var query = ""
  @State private var marked = 0
  @FocusState private var isFocused: Bool

  var body: some View {
    let matches = matches
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
        TextField("Search \(folder.name)...", text: $query).textFieldStyle(.plain).font(.system(size: 13))
          .focused($isFocused)
          .onSubmit { if matches.indices.contains(marked) { select(matches[marked].id) } }
          .onKeyPress(.downArrow) {
            marked = min(marked + 1, max(matches.count - 1, 0))
            return .handled
          }
          .onKeyPress(.upArrow) {
            marked = max(marked - 1, 0)
            return .handled
          }
      }
      .frame(height: 32)
      ForEach(Array(matches.enumerated()), id: \.element.id) { index, tab in
        Button { select(tab.id) } label: {
          Text(tab.displayTitle).font(.system(size: 13)).lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(index == marked ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 8)
    .padding(.bottom, 4)
    .frame(width: 236)
    .onAppear { isFocused = true }
    .onChange(of: query) { marked = 0 }
  }

  private var matches: [Tab] {
    query.isEmpty ? tabs : tabs.filter {
      $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query)
    }
  }
}
