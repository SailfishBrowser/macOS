import AppKit
import SwiftUI

// The theme picker (354x506): up to three color handles on a dotted canvas, where the angle around the center
// is hue and the distance from it saturation, with light and dark modes, pages of swatches, an intensity slider,
// a grain dial, and for an existing space Reset to original colors and the Advanced color controls.
struct ThemePicker: View {
  @Binding var theme: SpaceTheme
  @State private var handles: [Handle]
  @State private var mode = Mode.free
  @State private var page = 0
  @State private var grab: Grab?
  // The theme as the editor opened, for Reset to original colors and Original Saturation.
  private let original: SpaceTheme
  // An existing space's theme, which has original colors to go back to.
  private let isEditing: Bool

  enum Mode: String, CaseIterable {
    case free = "sparkles", light = "sun.max", dark = "moon"

    // The HSL lightness the light and dark modes give every color.
    var lightness: Double? {
      switch self {
      case .free: nil
      case .light: 0.85
      case .dark: 0.2
      }
    }
  }

  // A color as an offset from the canvas center within the unit circle, and its HSL lightness.
  struct Handle {
    var offset: CGPoint
    var lightness: Double
  }

  // Where a drag began, and the handle's center less that point, so the handle keeps its place under the pointer.
  struct Grab {
    var start: CGPoint
    var offset: CGSize
  }

  private static let size: CGFloat = 340
  private static let radius: CGFloat = 162
  // Brand, drab, greyscale and pastel pages.
  private static let swatches: [[UInt32]] = [
    [0xF1EAE5, 0xE69FBA, 0x9E749B, 0xE1686F, 0xEF8C62, 0xF2D66D, 0x73E59C, 0x7FB8D6, 0x666786],
    [0x4B3B58, 0x623856, 0x854444, 0xA77048, 0xD1B46A, 0xCDCCA8, 0x84A885, 0x34604B, 0x2D4468],
    [0xFFFFFF, 0xE5E5E5, 0xCCCCCC, 0xB2B2B2, 0x808080, 0x666666, 0x333333, 0x1A1A1A, 0x000000],
    [0xFDFBFA, 0xFBEAF3, 0xECD2EA, 0xF7CDD2, 0xFAE1D5, 0xFEF9E7, 0xE4FCEC, 0xE0F2FB, 0xC5C6E2],
  ]

  init(theme: Binding<SpaceTheme>, original: SpaceTheme, isEditing: Bool) {
    _theme = theme
    self.original = original
    self.isEditing = isEditing
    _handles = State(initialValue: theme.wrappedValue.colors.map(Self.handle))
  }

  var body: some View {
    VStack(spacing: 14) {
      canvas
      HStack(spacing: 0) {
        arrow("chevron.left", page - 1)
        ForEach(Self.swatches[page], id: \.self) { swatch in
          // Shot 33: 23.5 pt swatches at a 29.5 pt pitch.
          Circle().fill(Color(hex: swatch)).frame(width: 23.5, height: 23.5).frame(width: 29.5)
            .onTapGesture {
              var handle = Self.handle(swatch)
              handle.lightness = mode.lightness ?? handle.lightness
              withAnimation(Motion.layout) { handles = [handle] + handles.dropFirst() }
              tick()
              update()
            }
        }
        arrow("chevron.right", page + 1)
      }
      HStack(spacing: 22) {
        IntensitySlider(value: $theme.intensity, isEnabled: !handles.isEmpty)
        GrainDial(value: $theme.grain, isEnabled: !handles.isEmpty)
      }
      .padding(.leading, 10)
      if isEditing {
        HStack {
          Button("Reset to original colors") {
            theme = original
            withAnimation(Motion.layout) {
              handles = original.colors.map(Self.handle)
              mode = .free
            }
            tick()
          }
          .disabled(theme == original)
          Spacer()
          Menu("Advanced color controls") {
            Button("Invert Lightness") {
              withAnimation(Motion.layout) {
                for index in handles.indices { handles[index].lightness = 1 - handles[index].lightness }
                mode = .free
              }
              tick()
              update()
            }
            Button("Original Saturation") {
              let originals = original.colors.map(Self.handle)
              withAnimation(Motion.layout) {
                for index in handles.indices where originals.indices.contains(index) {
                  let angle = atan2(handles[index].offset.y, handles[index].offset.x)
                  let saturation = hypot(originals[index].offset.x, originals[index].offset.y)
                  handles[index].offset = CGPoint(x: cos(angle) * saturation, y: sin(angle) * saturation)
                }
              }
              tick()
              update()
            }
            .disabled(original.colors.isEmpty)
          }
          .fixedSize()
          .disabled(handles.isEmpty)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(.horizontal, 10)
      }
    }
    .padding(7)
    .frame(width: 354, height: 506, alignment: .top)
    .presentationBackground(panel)
    .environment(\.colorScheme, .dark)
  }

  // Shots 33 to 35: the panel is #2A2838 with no color, else the colors' average at half its brightness, which is
  // within 2 of the shots (#7FB8D6 gives #3F5C6B, measured #3F5A6B; #7FB8D6 and #D69C7E give #555555, measured #555557).
  private var panel: Color {
    if theme.colors.isEmpty { return Color(hex: 0x2A2838) }
    let channels = [16, 8, 0].map { (shift: UInt32) in
      theme.colors.map { Double($0 >> shift & 0xFF) }.reduce(0, +) / Double(theme.colors.count) / 255 / 2
    }
    return Color(red: channels[0], green: channels[1], blue: channels[2])
  }

  // The trackpad ticks as colors change.
  private func tick() {
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }

  private var canvas: some View {
    ZStack {
      Canvas { context, size in
        // Shot 33: 80 dots across the 340 pt canvas, 4.25 pt apart.
        for x in stride(from: 2.0, to: size.width, by: 4.25) {
          for y in stride(from: 2.0, to: size.height, by: 4.25) {
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(0.14)))
          }
        }
      }
      .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
      // A click on the canvas places the first color there, or moves the main one there, as the system color wheel does.
      .gesture(SpatialTapGesture().onEnded { tap in
        withAnimation(Motion.layout) {
          if handles.isEmpty { handles = [Handle(offset: .zero, lightness: 0.65)] }
          handles[0].lightness = mode.lightness ?? handles[0].lightness
          place(0, at: tap.location)
        }
        update()
      })
      if handles.isEmpty {
        Text("Tap to pick a color for this space").font(.system(size: 13, weight: .semibold)).allowsHitTesting(false)
      }
      ForEach(handles.indices, id: \.self) { index in
        let point = Self.point(handles[index])
        Circle()
          .fill(Color(hex: Self.hex(handles[index])))
          .frame(width: index == 0 ? 44 : 26, height: index == 0 ? 44 : 26)
          .overlay(Circle().strokeBorder(.white, lineWidth: index == 0 ? 4 : 3))
          .shadow(color: .black.opacity(0.3), radius: 3)
          .position(point)
          .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            let grab =
              grab.flatMap { $0.start == drag.startLocation ? $0 : nil }
              ?? Grab(
                start: drag.startLocation,
                offset: CGSize(width: point.x - drag.startLocation.x, height: point.y - drag.startLocation.y))
            self.grab = grab
            place(index, at: CGPoint(x: drag.location.x + grab.offset.width, y: drag.location.y + grab.offset.height))
            update()
          })
          // A color added or removed grows in from, or shrinks out to, 60% where it sits.
          .transition(
            .scale(scale: 0.6, anchor: UnitPoint(x: point.x / Self.size, y: point.y / Self.size))
              .combined(with: .opacity))
      }
      VStack {
        // Shot 33: the mode buttons 40 pt apart, their row 24 pt under the canvas's top; minus and plus 16 pt above its bottom.
        HStack(spacing: 8) {
          ForEach(Mode.allCases, id: \.self) { item in
            button(item.rawValue, isSelected: mode == item) {
              withAnimation(Motion.layout) {
                mode = item
                if let lightness = item.lightness {
                  for index in handles.indices { handles[index].lightness = lightness }
                }
              }
              tick()
              update()
            }
          }
        }
        Spacer()
        HStack(spacing: 8) {
          button("minus", isSelected: false) {
            withAnimation(Motion.layout) { _ = handles.removeLast() }
            tick()
            update()
          }
          .disabled(handles.isEmpty)
          // Up to three colors spaced evenly round the first at its distance: the second opposite it, as in shot 35.
          button("plus", isSelected: false) {
            let turn = 2 * Double.pi / Double(handles.count + 1)
            withAnimation(Motion.layout) {
              handles.append(Handle(offset: .zero, lightness: handles.last!.lightness))
              let first = handles[0].offset
              for index in handles.indices.dropFirst() {
                let angle = turn * Double(index)
                handles[index].offset = CGPoint(
                  x: first.x * cos(angle) - first.y * sin(angle), y: first.x * sin(angle) + first.y * cos(angle))
              }
            }
            tick()
            update()
          }
          .disabled(handles.isEmpty || handles.count == 3)
        }
      }
      .padding(.top, 24)
      .padding(.bottom, 16)
    }
    .frame(width: Self.size, height: Self.size)
  }

  private func arrow(_ systemName: String, _ target: Int) -> some View {
    let isEnabled = Self.swatches.indices.contains(target)
    return Button { page = target } label: {
      // Shot 33: a 14 pt tall chevron at white 57%.
      Image(systemName: systemName).font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 30, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.35)
    .disabled(!isEnabled)
  }

  private func button(_ systemName: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      // Shot 33: 17 pt glyphs on a 32 pt square.
      Image(systemName: systemName).font(.system(size: 16, weight: .medium))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .frame(width: 32, height: 32)
        .background(isSelected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func place(_ index: Int, at location: CGPoint) {
    let x = (location.x - Self.size / 2) / Self.radius
    let y = (location.y - Self.size / 2) / Self.radius
    let scale = max(hypot(x, y), 1)
    handles[index].offset = CGPoint(x: x / scale, y: y / scale)
  }

  private static func point(_ handle: Handle) -> CGPoint {
    CGPoint(x: size / 2 + handle.offset.x * radius, y: size / 2 + handle.offset.y * radius)
  }

  private func update() {
    theme.colors = handles.map(Self.hex)
  }

  private static func hex(_ handle: Handle) -> UInt32 {
    let hue = atan2(handle.offset.y, handle.offset.x) / (2 * .pi)
    let saturation = hypot(handle.offset.x, handle.offset.y)
    let brightness = handle.lightness + saturation * min(handle.lightness, 1 - handle.lightness)
    let color = NSColor(
      hue: hue < 0 ? hue + 1 : hue, saturation: brightness == 0 ? 0 : 2 * (1 - handle.lightness / brightness),
      brightness: brightness, alpha: 1
    )
    .usingColorSpace(.sRGB)!
    return UInt32((color.redComponent * 255).rounded()) << 16 | UInt32((color.greenComponent * 255).rounded()) << 8
      | UInt32((color.blueComponent * 255).rounded())
  }

  // Where a color sits on the canvas, from its HSL hue and saturation.
  private static func handle(_ hex: UInt32) -> Handle {
    let color = NSColor(Color(hex: hex)).usingColorSpace(.sRGB)!
    let lightness = color.brightnessComponent * (1 - color.saturationComponent / 2)
    let range = min(lightness, 1 - lightness)
    let saturation = range == 0 ? 0 : (color.brightnessComponent - lightness) / range
    let angle = color.hueComponent * 2 * .pi
    return Handle(offset: CGPoint(x: cos(angle) * saturation, y: sin(angle) * saturation), lightness: lightness)
  }
}

// The wavy intensity slider with a tall pill thumb.
private struct IntensitySlider: View {
  @Binding var value: Double
  let isEnabled: Bool

  var body: some View {
    GeometryReader { proxy in
      let x = 11 + value * (proxy.size.width - 22)
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.06)).frame(height: 22)
        Wave().stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        if isEnabled {
          Wave().stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .mask(alignment: .leading) { Rectangle().frame(width: x) }
          Capsule().fill(.white).frame(width: 23, height: 55).position(x: x, y: proxy.size.height / 2)
        }
      }
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0).onChanged {
        value = min(max(($0.location.x - 11) / (proxy.size.width - 22), 0), 1)
      })
    }
    .frame(width: 224, height: 55)
    .disabled(!isEnabled)
  }

  private struct Wave: Shape {
    func path(in rect: CGRect) -> Path {
      Path { path in
        let inset = rect.insetBy(dx: 8, dy: 15)
        path.move(to: CGPoint(x: inset.minX, y: inset.midY))
        for x in stride(from: 0, through: inset.width, by: 1) {
          path.addLine(to: CGPoint(x: inset.minX + x, y: inset.midY - sin(x / inset.width * 12 * .pi) * inset.height / 2))
        }
      }
    }
  }
}

// The grain dial: a knob turned clockwise from the top around a ring of dots.
private struct GrainDial: View {
  @Binding var value: Double
  let isEnabled: Bool

  var body: some View {
    ZStack {
      ForEach(0..<24, id: \.self) { index in
        Circle().fill(.white.opacity(isEnabled && Double(index) / 24 < value ? 0.7 : 0.3)).frame(width: 3, height: 3)
          .offset(y: -33)
          .rotationEffect(.degrees(Double(index) * 15))
      }
      Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1.5).frame(width: 40, height: 40)
      if isEnabled {
        Capsule().fill(.white).frame(width: 5, height: 13).offset(y: -32).rotationEffect(.degrees(value * 360))
      }
    }
    .frame(width: 72, height: 72)
    .contentShape(Circle())
    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
      let angle = atan2(drag.location.x - 36, 36 - drag.location.y) / (2 * .pi)
      let turned = angle < 0 ? angle + 1 : angle
      if abs(turned - value) < 0.5 { value = turned }
    })
    .disabled(!isEnabled)
  }
}

// The theme being edited, which the window shows while the editor is open.
struct ThemePreview: PreferenceKey {
  static let defaultValue: SpaceTheme? = nil

  static func reduce(value: inout SpaceTheme?, nextValue: () -> SpaceTheme?) {
    value = value ?? nextValue()
  }
}
