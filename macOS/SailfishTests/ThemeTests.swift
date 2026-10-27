import AppKit
import SwiftUI
import XCTest

@testable import Sailfish

final class ThemeTests: XCTestCase {
  private func rgb(_ color: Color) -> [Double] {
    let color = NSColor(color).usingColorSpace(.deviceRGB)!
    return [color.redComponent, color.greenComponent, color.blueComponent]
      .map { (Double($0) * 1000).rounded() / 1000 }
  }

  func testSelectedRowsTakeTheSpacesPrimaryColor() {
    let sky = Theme.rowSelection(SpaceTheme(colors: [0x9CC7E8, 0xC9B8E8]))
    let rose = Theme.rowSelection(SpaceTheme(colors: [0xE8A0A8, 0xE8C090]))
    let forest = Theme.rowSelection(SpaceTheme(colors: [0x173A2A]))
    let plum = Theme.rowSelection(SpaceTheme(colors: [0x4A1F5C]))
    XCTAssertNotEqual(rgb(sky), rgb(rose))
    XCTAssertNotEqual(rgb(forest), rgb(plum))
    XCTAssertGreaterThan(rgb(sky)[2], rgb(sky)[0])
  }

  func testGreyThemesKeepANeutralSelection() {
    let grey = rgb(Theme.rowSelection(SpaceTheme(colors: [0xC8C8C8])))
    XCTAssertEqual(grey[0], grey[1])
    XCTAssertEqual(grey[1], grey[2])
  }

  func testAccentPassesContrastWithWhiteText() {
    let accent = NSColor(named: "AccentColor")!.usingColorSpace(.sRGB)!
    func linear(_ channel: CGFloat) -> Double {
      let c = Double(channel)
      return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    let luminance = 0.2126 * linear(accent.redComponent) + 0.7152 * linear(accent.greenComponent)
      + 0.0722 * linear(accent.blueComponent)
    XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5)
  }
}
