import SwiftUI

// The Favorites grid: the tiles in one order, wrapped into as few rows as hold four and as even as they go, the
// blanks at the end of the last row. Every cell has the same size, so a tile that wraps to the next row slides there.
struct FavoriteGrid: Layout {
  static let spacing: CGFloat = 8
  // The tile is 47 pt tall.
  static let tileHeight: CGFloat = 47

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.replacingUnspecifiedDimensions().width
    let rows = Self.rows(subviews.count)
    return CGSize(width: width, height: rows == 0 ? 0 : CGFloat(rows) * (Self.tileHeight + Self.spacing) - Self.spacing)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (index, subview) in subviews.enumerated() {
      let cell = Self.cell(index, of: subviews.count, in: bounds)
      subview.place(at: CGPoint(x: cell.midX, y: cell.midY), anchor: .center, proposal: ProposedViewSize(cell.size))
    }
  }

  private static func rows(_ count: Int) -> Int {
    count == 0 ? 0 : (count + Space.favoriteColumns(count) - 1) / Space.favoriteColumns(count)
  }

  private static func cellWidth(_ count: Int, in width: CGFloat) -> CGFloat {
    let columns = CGFloat(Space.favoriteColumns(count))
    return (width - spacing * (columns - 1)) / columns
  }

  private static func cell(_ index: Int, of count: Int, in bounds: CGRect) -> CGRect {
    let columns = Space.favoriteColumns(count)
    let width = cellWidth(count, in: bounds.width)
    return CGRect(
      x: bounds.minX + CGFloat(index % columns) * (width + spacing),
      y: bounds.minY + CGFloat(index / columns) * (tileHeight + spacing), width: width, height: tileHeight)
  }

  // The cell under a point, among a grid of this many cells at this frame: where a dragged tile goes. The placeholder
  // is one of the cells, so their number holds while the pointer moves over the grid and the cells keep still. A gap
  // splits at its middle, and a point past the grid takes the nearest row and column, or the last cell.
  static func index(at point: CGPoint, cells count: Int, in frame: CGRect) -> Int {
    guard count > 1 else { return 0 }
    let columns = Space.favoriteColumns(count)
    // Clamped before it becomes an Int, and never divided by zero, however narrow the grid.
    let pitch = max(cellWidth(count, in: frame.width) + spacing, 1)
    let column = min(max(((point.x - frame.minX + spacing / 2) / pitch).rounded(.down), 0), CGFloat(columns - 1))
    let row = min(
      max(((point.y - frame.minY + spacing / 2) / (tileHeight + spacing)).rounded(.down), 0), CGFloat(rows(count) - 1))
    return min(Int(row) * columns + Int(column), count - 1)
  }
}
