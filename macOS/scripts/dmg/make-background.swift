// Renders background.tiff, the DMG window's background (dmg.json): 1x and 2x combined with tiffutil -cathidpicheck.
// Usage: swift macOS/scripts/dmg/make-background.swift
import AppKit

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let size = CGSize(width: 800, height: 400)
func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func draw() {
  let ctx = NSGraphicsContext.current!.cgContext
  color(0xF6F4EF).setFill()
  CGRect(origin: .zero, size: size).fill()
  let washes: [(CGPoint, CGFloat, NSColor)] = [
    (CGPoint(x: 0, y: size.height), 280, color(0x2290C9, 0.2)),
    (CGPoint(x: size.width, y: size.height), 300, color(0xDCEAF2)),
    (CGPoint(x: 0, y: 0), 300, color(0xDCEAF2)),
    (CGPoint(x: size.width, y: 0), 260, color(0x2290C9, 0.14)),
  ]
  for (center, radius, tint) in washes {
    let gradient = CGGradient(colorsSpace: nil, colors: [tint.cgColor, tint.withAlphaComponent(0).cgColor] as CFArray, locations: nil)!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
  }

  let regular: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: color(0x6E6E73)]
  let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: color(0x1D1D1F)]
  let line = NSMutableAttributedString()
  for (text, attributes) in [("To install, drag ", regular), ("Sailfish", bold), (" to ", regular), ("Applications", bold)] {
    line.append(NSAttributedString(string: text, attributes: attributes))
  }
  let bounds = line.size()
  line.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: size.height - 62 - bounds.height / 2))

  ctx.setLineWidth(3.2)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)
  for (i, alpha) in [0.22, 0.55, 1].enumerated() {
    let x = size.width / 2 - 19 + CGFloat(i) * 15
    let y = size.height - 205
    ctx.move(to: CGPoint(x: x, y: y + 10))
    ctx.addLine(to: CGPoint(x: x + 8, y: y))
    ctx.addLine(to: CGPoint(x: x, y: y - 10))
    ctx.setStrokeColor(color(0x003A5F, alpha).cgColor)
    ctx.strokePath()
  }
}

func png(_ scale: Int) -> URL {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    .retagging(with: .sRGB)!
  rep.size = size
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  draw()
  NSGraphicsContext.current = nil
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("background@\(scale)x.png")
  try! rep.representation(using: .png, properties: [:])!.write(to: url)
  return url
}

let images = [png(1), png(2)]
let tiffutil = try! Process.run(
  URL(fileURLWithPath: "/usr/bin/tiffutil"),
  arguments: ["-cathidpicheck"] + images.map(\.path) + ["-out", dir.appendingPathComponent("background.tiff").path])
tiffutil.waitUntilExit()
images.forEach { try! FileManager.default.removeItem(at: $0) }
