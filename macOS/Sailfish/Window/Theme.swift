import AppKit
import SwiftUI

// A space's theme: up to three colors, grain and color intensity.
struct SpaceTheme: Codable, Equatable {
  var colors: [UInt32] = []
  var grain = 0.0
  var intensity = 0.8

  // The default dark gradient when no color is picked, in sRGB.
  var gradient: [UInt32] { colors.isEmpty ? [0x0E0F21, 0x1F0B22] : colors }
  // Picked colors are laid over the translucent window as strongly as the intensity says.
  var opacity: Double { colors.isEmpty ? 1 : intensity }
}

enum Theme {
  // Sailfish's blue (#1D7DAF): the website's "sea" (#2290C9) deepened so white text on it reaches 4.5:1, kept in the
  // AccentColor asset so SwiftUI's accent follows it.
  static let accent = Color("AccentColor")
  // The website's "foam" and "navy": a light tint of the accent and the ink on it.
  static let accentTint = Color(hex: 0xDCEAF2)
  static let accentInk = Color(hex: 0x003A5F)

  // Light themes get dark text: the text color that contrasts more with the gradient's average
  // luminance wins, which flips at a luminance of about 0.18.
  static func isLight(_ theme: SpaceTheme) -> Bool {
    let luminance = theme.gradient.map(Self.luminance).reduce(0, +) / Double(theme.gradient.count)
    return (luminance + 0.05) * (luminance + 0.05) > 1.05 * 0.05
  }

  private static func luminance(_ hex: UInt32) -> Double {
    func linear(_ shift: UInt32) -> Double {
      let channel = Double(hex >> shift & 0xFF) / 255
      return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
  }
  static let incognitoWindow = LinearGradient(colors: [Color(hex: 0x0D0F13)], startPoint: .top, endPoint: .bottom)
  static let incognitoCard = LinearGradient(colors: [Color(hex: 0x26272A)], startPoint: .top, endPoint: .bottom)
  static let incognitoPill = Color(hex: 0x313436)
  // The empty page over the default dark theme, in sRGB.
  static let card = LinearGradient(
    colors: [Color(hex: 0x272738), Color(hex: 0x372338)], startPoint: .topLeading, endPoint: .bottomTrailing)
  static let findBar = Color(hex: 0x151C30)
  static let notFound = Color(hex: 0xFF453A)

  enum CommandBar {
    static let width: CGFloat = 766
    // The panel: 11.85pt continuous.
    static let radius: CGFloat = 12
    static let inputHeight: CGFloat = 64
    static let rowHeight: CGFloat = 46
    static let rowSpacing: CGFloat = 4
    static let rowsTop: CGFloat = 6
    static let rowsBottom: CGFloat = 12
    // The separator is one device pixel of white at 0.1; this is its share of the layout on Retina.
    static let separatorHeight: CGFloat = 0.5
    // The panel with five rows: the input, the separator, the rows and their paddings.
    static let fiveRowHeight: CGFloat = inputHeight + separatorHeight + rowsTop + 5 * rowHeight + 4 * rowSpacing + rowsBottom
    static let inset: CGFloat = 10
    // Icons are centered 32 pt from the panel edge; text starts 20 pt after.
    static let iconLeading: CGFloat = 24
    static let textSpacing: CGFloat = 12
    // Arc's panel follows the space's theme: light themes get a light panel (measured on Arc 1.170: body #F8F8F8,
    // text #3C3D3F, placeholder #BBBBBB, separator #DEDFDF, rim #A4A4A4, inline selection #A5AAFF), dark ones the
    // dark panel. The dark values are from the owner's Retina screenshot of Arc over a purple space: row title
    // #D1D1D2, row icon #BABABC, field icon white, info badge #050625 with a #8F8F9D ring.
    // Over .ultraThinMaterial, which passes 58% of the page's contrast: Arc lets 11% of the blurred page through, #151618
    // over shot 13's black band, #2E2B24 over its sand and #1A181B over the owner's purple page.
    static let background = adaptive(Color(hex: 0x141517).opacity(0.8), Color(hex: 0xF8F8F8).opacity(0.96))
    // Arc's rim: one device pixel of #030203, then 1 pt of #4E4D4F.
    static let outerLine = adaptive(Color(hex: 0x030203), Color(hex: 0xA4A4A4))
    static let innerLine = adaptive(Color(hex: 0x4E4D4F), .white.opacity(0.5))
    // Arc's shadow fitted on the owner's screenshot: Gaussian sigma 47 pt, 25 pt down, 0.50 at full cover.
    static let shadowOpacity = 0.5
    static let shadowRadius: CGFloat = 47
    static let shadowY: CGFloat = 24
    static let separator = adaptive(.white.opacity(0.1), .black.opacity(0.1))
    static let placeholder = adaptive(.white.opacity(0.3), .black.opacity(0.3))
    // Inline completion on the default dark theme: #747786.
    static let textSelection = adaptive(Color(hex: 0x747786), Theme.accent.opacity(0.4))
    static let text = adaptive(Color(hex: 0xE4E5E9), Color(hex: 0x3C3D3F))
    static let title = adaptive(Color(hex: 0xD1D1D2), Color(hex: 0x323232))
    static let icon = adaptive(Color(hex: 0xBABABC), Color(hex: 0x323232))
    static let fieldIcon = adaptive(.white, Color(hex: 0x3C3D3F))
    // " — domain" and the site-search hint: #676868 on the dark panel, kept legible over a light page seen
    // through the glass.
    static let detail = adaptive(.white.opacity(0.42), .black.opacity(0.42))
    static let infoFill = adaptive(Color(hex: 0x050625), .black.opacity(0.06))
    static let infoGlyph = adaptive(Color(hex: 0x8F8F9D), Color(hex: 0x6E7072))
    // Little Sailfish's close button: white at 0.08.
    static let fill = adaptive(.white.opacity(0.08), .black.opacity(0.06))
    // The Tab keycap and the Switch to Tab arrow: white at 0.05 (shots 11 and 13).
    static let keycap = adaptive(.white.opacity(0.05), .black.opacity(0.06))
    // The Tab keycap's label: #B9B8B8.
    static let keycapText = adaptive(Color(hex: 0xB9B8B8), Color(hex: 0x323232))
    // Little Sailfish's close glyph: #A6A5A7.
    static let closeGlyph = adaptive(Color(hex: 0xA6A5A7), Color(hex: 0x323232))
    static let hover = adaptive(.white.opacity(0.05), .black.opacity(0.04))

    // The selected row's fill and the chips' color: on a light theme a light tint of the theme's hue,
    // on a dark one the accent whatever the theme.
    static func accent(_ theme: SpaceTheme) -> Color {
      guard Theme.isLight(theme) else { return Theme.accent }
      let color = NSColor(Color(hex: theme.gradient[0])).usingColorSpace(.deviceRGB)!
      return Color(hue: color.hueComponent, saturation: 0.44, brightness: 1)
    }
  }

  // A space's accent: its theme's hue, bright on dark themes (#4247CF) and muted on light ones (#406C7F).
  static func accent(_ theme: SpaceTheme) -> Color {
    let isLight = isLight(theme)
    return shade(theme, saturation: isLight ? 0.5 : 0.68, brightness: isLight ? 0.5 : 0.81)
  }
  // A disabled accent button keeps its hue: on dark themes saturated and dark (#18197A) with text in a muted
  // accent (#5B62C8); on light themes a washed version of the muted accent.
  static func disabledAccentFill(_ theme: SpaceTheme) -> Color {
    isLight(theme) ? shade(theme, saturation: 0.3, brightness: 0.62) : shade(theme, saturation: 0.8, brightness: 0.48)
  }
  static func disabledAccentText(_ theme: SpaceTheme) -> Color {
    isLight(theme) ? shade(theme, saturation: 0.15, brightness: 0.9) : shade(theme, saturation: 0.55, brightness: 0.78)
  }
  // The selected favorite's ring: the theme's colors as soft pastels (such as #ECB3B7 to #EBB883), going round the tile.
  static func favoriteRing(_ theme: SpaceTheme) -> AngularGradient {
    let colors = theme.gradient.map { tint($0, saturation: 0.35, brightness: 0.95) }
    return AngularGradient(colors: colors + colors.prefix(1), center: .center)
  }
  // A selected tab row or favorite, lit with the space's primary color: a light tint of it on light themes, a
  // translucent one on dark themes (white at 19% takes the color of the sidebar under it).
  static func rowSelection(_ theme: SpaceTheme) -> Color {
    isLight(theme)
      ? tint(theme.gradient[0], saturation: 0.22, brightness: 1).opacity(0.85)
      : tint(theme.gradient[0], saturation: 0.5, brightness: 1).opacity(0.2)
  }
  // A color's hue at the given saturation, scaled down for greys so they stay grey rather than take hue 0's red.
  private static func tint(_ hex: UInt32, saturation: Double, brightness: Double) -> Color {
    let color = NSColor(Color(hex: hex)).usingColorSpace(.deviceRGB)!
    return Color(
      hue: color.hueComponent, saturation: saturation * min(color.saturationComponent / 0.3, 1), brightness: brightness)
  }
  private static func shade(_ theme: SpaceTheme, saturation: Double, brightness: Double) -> Color {
    let color = NSColor(Color(hex: theme.gradient[0])).usingColorSpace(.deviceRGB)!
    return Color(hue: color.hueComponent, saturation: saturation, brightness: brightness)
  }
  static let menu = Color(hex: 0x050726)
  static let menuSeparator = Color(hex: 0x272A78)
  static let menuSelection = accent.opacity(0.5)
  static let menuShortcut = Color(hex: 0x9B9AA8)
  static let favoritesBorder = adaptive(Color(hex: 0x3F3F55), .white.opacity(0.3))
  // The hint box has no fill on dark themes.
  static let favoritesHintFill = adaptive(.clear, .white.opacity(0.2))
  // Sidebar colors follow the window's appearance, which follows the theme. On a dark theme the secondary text and
  // icons are white over the window, so they take its tint: the space title 45%, icons 60%, the empty pill's text
  // 30% and its magnifier 40%. The lit New Tab label is #DEDFFF.
  static let primaryText = adaptive(Color(hex: 0xEDEDF2), Color(hex: 0x14191C))
  // Tab titles and the lit New Tab label: #DEDFFF (another capture read #DAD8FF).
  static let rowText = adaptive(Color(hex: 0xDEDFFF), Color(hex: 0x14191C))
  // The URL in the pill: white at 56% over the pill.
  static let pillText = adaptive(.white.opacity(0.56), Color(hex: 0x14191C).opacity(0.8))
  static let secondaryText = adaptive(.white.opacity(0.45), .black.opacity(0.45))
  static let icon = adaptive(.white.opacity(0.6), .black.opacity(0.55))
  static let pillPlaceholder = adaptive(.white.opacity(0.3), Color(hex: 0x14191C).opacity(0.33))
  static let pillIcon = adaptive(.white.opacity(0.4), Color(hex: 0x14191C).opacity(0.33))
  // Hover darkens on light themes too.
  static let hover = adaptive(.white.opacity(0.07), .black.opacity(0.04))
  // A hovered tab or folder row: white 10%, black 4%.
  static let rowHover = adaptive(.white.opacity(0.1), .black.opacity(0.04))
  // The divider's Clear label: white 30%, black 32%.
  static let clearLabel = adaptive(.white.opacity(0.3), .black.opacity(0.32))
  static let trafficLight = adaptive(.white.opacity(0.3), .black.opacity(0.1))
  // The footer dots: the current space's at about half strength, the others faint.
  static let spaceDot = adaptive(.white.opacity(0.52), .black.opacity(0.53))
  static let spaceDotOther = adaptive(.white.opacity(0.18), .black.opacity(0.28))
  static let selection = adaptive(.white.opacity(0.13), .white.opacity(0.85))
  // The selected row casts no shadow on a dark theme; on a light one it does.
  static let rowShadow = adaptive(.clear, .black.opacity(0.12))
  static let fill = adaptive(.white.opacity(0.1), .black.opacity(0.05))
  static let fillHover = adaptive(.white.opacity(0.14), .black.opacity(0.09))
  // The space editor's name field, focused or not: white 8% on the default dark theme, 60% on a light one (shots 31, 32, 36).
  static let field = adaptive(.white.opacity(0.08), .white.opacity(0.6))
  // The half of a row a dragged tab will split into, and its flash on release (a 6% accent tint, then solid).
  static let splitHalf = adaptive(.white.opacity(0.12), accent.opacity(0.07))
  static let splitFlash = accent
  static let divider = adaptive(.white.opacity(0.12), .black.opacity(0.12))
  static let floatingRim = Color.white.opacity(0.2)
  // The tab switcher's panel and its cards' thumbnails.
  static let switcher = adaptive(Color(hex: 0x1C1D27), Color(hex: 0xF8F8F8))
  static let switcherRim = adaptive(.white.opacity(0.14), Color(hex: 0xA4A4A4))

  private static func adaptive(_ dark: Color, _ light: Color) -> Color {
    Color(nsColor: NSColor(name: nil) {
      $0.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? NSColor(light) : NSColor(dark)
    })
  }
}

// Film grain drawn from random noise, tiled over a theme's gradient.
struct Grain: View {
  let amount: Double

  private static let tile: Image = {
    let size = 256
    let noise = Data((0..<size * size).map { _ in UInt8.random(in: 0...255) })
    let image = CGImage(
      width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: CGDataProvider(data: noise as CFData)!,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return Image(decorative: image, scale: 2)
  }()

  var body: some View {
    Rectangle().fill(ImagePaint(image: Self.tile)).blendMode(.overlay).opacity(amount * 0.25).allowsHitTesting(false)
  }
}

// The blurred desktop behind the window, which a theme's intensity lets show through.
struct WindowBlur: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .behindWindow
    view.material = .underWindowBackground
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension LinearGradient {
  init(theme: SpaceTheme) {
    self.init(colors: theme.gradient.map(Color.init(hex:)), startPoint: .topLeading, endPoint: .bottomTrailing)
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(
      red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}
