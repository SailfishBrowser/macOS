// Renders the app icon into Sailfish/Assets.xcassets/AppIcon.appiconset from brand/sailfish-icon-1024.png, the
// master the iOS icon uses. The master is a full-bleed square (iOS masks it); macOS does not mask app icons, so
// each size places it on the macOS icon grid's rounded tile: 824 x 824 inset 100 on the 1024 canvas, corner
// radius 185. Every size is a Lanczos downscale of the master onto a tile snapped to whole pixels, so the tile's
// edges stay sharp at 16 and 32.
// Usage: swift macOS/scripts/make-icon.swift
import AppKit
import CoreImage.CIFilterBuiltins

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..")
let master = CIImage(contentsOf: root.appendingPathComponent("brand/sailfish-icon-1024.png"))!
let dir = root.appendingPathComponent("macOS/Sailfish/Assets.xcassets/AppIcon.appiconset")
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: sRGB])

func render(_ pixels: Int) -> Data {
  let inset = pixels * 100 / 1024
  let side = pixels - 2 * inset
  let scale = CIFilter.lanczosScaleTransform()
  scale.inputImage = master
  scale.scale = Float(side) / 1024
  let art = ci.createCGImage(scale.outputImage!, from: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: sRGB)!
  let ctx = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let tile = CGRect(x: inset, y: inset, width: side, height: side)
  let radius = CGFloat(side) * 185 / 824
  ctx.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
  ctx.clip()
  ctx.draw(art, in: tile)
  return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try render(points * scale).write(to: dir.appendingPathComponent(name))
  }
}
