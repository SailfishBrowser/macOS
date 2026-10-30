import AppKit
import SwiftUI

// The color of the favicon a tab shows, passed up to the favorites tile that tints itself with it.
struct FaviconColor: PreferenceKey {
  static let defaultValue: Color? = nil
  static func reduce(value: inout Color?, nextValue: () -> Color?) { value = value ?? nextValue() }
}

extension NSImage {
  // The icon's representative color: the average of its most common hue among the colored pixels of a 16x16 sample.
  // An icon of greys, such as GitHub's, has none. Worked out once per image.
  var representativeColor: Color? {
    if let known = Self.representativeColors.object(forKey: self) { return known.color }
    let color = sampledColor
    Self.representativeColors.setObject(KnownColor(color: color), forKey: self)
    return color
  }

  // NSCache is thread-safe.
  nonisolated(unsafe) private static let representativeColors = NSCache<NSImage, KnownColor>()

  private var sampledColor: Color? {
    let side = 16
    guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
    let pixels = UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: side * side * 4)
    // Twelve hue buckets of 30 degrees, each summing its pixels' red, green and blue and counting them.
    var buckets = Array(repeating: (red: 0.0, green: 0.0, blue: 0.0, count: 0), count: 12)
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
      buckets[bucket].count += 1
    }
    let top = buckets.max { $0.count < $1.count }!
    guard top.count > 0 else { return nil }
    let count = Double(top.count)
    return Color(.sRGB, red: top.red / count, green: top.green / count, blue: top.blue / count)
  }
}

private final class KnownColor {
  let color: Color?
  init(color: Color?) { self.color = color }
}
