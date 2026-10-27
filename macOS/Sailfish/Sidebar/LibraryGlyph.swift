import SwiftUI

// The Library glyph: a filled box under its lid, with two sparkles above its right corner.
struct LibraryGlyph: View {
  var body: some View {
    Canvas { context, size in
      let w = size.width
      context.fill(Path(roundedRect: CGRect(x: 0, y: 5, width: w, height: 3.5), cornerRadius: 1), with: .foreground)
      var box = Path(roundedRect: CGRect(x: 1.5, y: 9.5, width: w - 3, height: size.height - 9.5), cornerRadius: 1.5)
      box.addRoundedRect(in: CGRect(x: w / 2 - 2, y: 11.5, width: 4, height: 1.2), cornerSize: CGSize(width: 0.6, height: 0.6))
      context.fill(box, with: .foreground, style: FillStyle(eoFill: true))
      context.fill(Self.sparkle(at: CGPoint(x: w - 3, y: 2), radius: 2.2), with: .foreground)
      context.fill(Self.sparkle(at: CGPoint(x: w - 8, y: 1.5), radius: 1.3), with: .foreground)
    }
    .frame(width: 14, height: 17)
  }

  private static func sparkle(at c: CGPoint, radius r: CGFloat) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: c.x, y: c.y - r))
    path.addLine(to: CGPoint(x: c.x + r * 0.3, y: c.y - r * 0.3))
    path.addLine(to: CGPoint(x: c.x + r, y: c.y))
    path.addLine(to: CGPoint(x: c.x + r * 0.3, y: c.y + r * 0.3))
    path.addLine(to: CGPoint(x: c.x, y: c.y + r))
    path.addLine(to: CGPoint(x: c.x - r * 0.3, y: c.y + r * 0.3))
    path.addLine(to: CGPoint(x: c.x - r, y: c.y))
    path.addLine(to: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.3))
    path.closeSubpath()
    return path
  }
}
