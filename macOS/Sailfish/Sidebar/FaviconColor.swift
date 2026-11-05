import AppKit
import SwiftUI

// The colors of the favicon a tab shows, passed up to the favorites tile that is washed and bordered with them when
// selected.
struct FaviconColor: PreferenceKey {
  static let defaultValue: [Color] = []
  static func reduce(value: inout [Color], nextValue: () -> [Color]) { value = value.isEmpty ? nextValue() : value }
}

extension NSImage {
  // The icon's dominant colors, up to four: the average color of each hue that holds at least a tenth of the colored
  // pixels of a 16x16 sample, in clockwise order around the icon from its leading side. An icon of greys, such as
  // GitHub's, has none. Worked out once per image.
  var dominantColors: [Color] {
    if let known = Self.dominantColors.object(forKey: self) { return known.colors }
    let colors = sampledColors
    Self.dominantColors.setObject(KnownColors(colors: colors), forKey: self)
    return colors
  }

  // NSCache is thread-safe.
  nonisolated(unsafe) private static let dominantColors = NSCache<NSImage, KnownColors>()

  private var sampledColors: [Color] {
    let side = 16
    guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return [] }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
    let pixels = UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: side * side * 4)
    // Twelve hue buckets of 30 degrees, each summing its pixels' red, green and blue and their offsets from the
    // icon's center (rows run top to bottom), and counting them.
    var buckets = Array(repeating: (red: 0.0, green: 0.0, blue: 0.0, x: 0.0, y: 0.0, count: 0), count: 12)
    for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 128 {
      let alpha = Double(pixels[i + 3])
      let color = NSColor(
        srgbRed: Double(pixels[i]) / alpha, green: Double(pixels[i + 1]) / alpha, blue: Double(pixels[i + 2]) / alpha,
        alpha: 1)
      guard color.saturationComponent > 0.25, color.brightnessComponent > 0.2 else { continue }
      let bucket = min(Int(color.hueComponent * 12), 11)
      buckets[bucket].red += color.redComponent
      buckets[bucket].green += color.greenComponent
      buckets[bucket].blue += color.blueComponent
      buckets[bucket].x += Double(i / 4 % side) - Double(side - 1) / 2
      buckets[bucket].y += Double(i / 4 / side) - Double(side - 1) / 2
      buckets[bucket].count += 1
    }
    let colored = buckets.map(\.count).reduce(0, +)
    return buckets.filter { $0.count > 0 && $0.count * 10 >= colored }
      .sorted { $0.count > $1.count }.prefix(4)
      .sorted { atan2($0.y, $0.x) < atan2($1.y, $1.x) }
      .map {
        let count = Double($0.count)
        return Color(.sRGB, red: $0.red / count, green: $0.green / count, blue: $0.blue / count)
      }
  }
}

private final class KnownColors {
  let colors: [Color]
  init(colors: [Color]) { self.colors = colors }
}
