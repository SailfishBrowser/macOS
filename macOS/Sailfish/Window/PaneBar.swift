import SwiftUI

// A split pane's own toolbar, in the page's own color: back, forward and the domain on every pane;
// reload, site controls and Split View Options only on the focused one. The domain edits the pane's URL.
struct PaneBar: View {
  let tab: Tab
  let space: Space
  let isFocused: Bool
  // The split's panes, left to right.
  let panes: [Tab.ID]
  let isExpanded: Bool
  let act: (TabsFeature.Action) -> Void
  let open: (URL) -> Void
  let split: () -> Void
  let close: () -> Void
  let edit: () -> Void
  let expand: () -> Void
  @State private var pageColor: Color?
  // Which load the color is for, so a snapshot of an earlier page cannot color the bar.
  @State private var generation = 0
  @State private var showsControls = false

  var body: some View {
    let color = pageColor ?? .white
    let isLight = NSColor(color).usingColorSpace(.deviceRGB)!.brightnessComponent > 0.5
    // Shot 65: back, forward and reload 37 pt apart, the first 21 pt in; close 22 pt from the end, split 32 pt
    // before it and site controls 36 before that.
    HStack(spacing: 0) {
      HStack(spacing: 9) {
        BarButton(systemName: "arrow.left", isEnabled: tab.canGoBack) { act(.goBack) }
        BarButton(systemName: "arrow.right", isEnabled: tab.canGoForward) { act(.goForward) }
        if isFocused {
          BarButton(systemName: tab.isLoading ? "xmark" : "arrow.clockwise") { act(tab.isLoading ? .stop : .reload) }
        }
      }
      Spacer()
      if isFocused {
        BarButton(systemName: "slider.horizontal.2.square") { showsControls = true }
          .help("Site Controls")
          .popover(isPresented: $showsControls, arrowEdge: .bottom) {
            if let contents = Engine.shared.tabs[tab.id] {
              SiteControls(space: space, tab: tab.id, contents: contents, url: tab.url, open: open)
            }
          }
        Menu { options } label: {
          Image(systemName: "rectangle.split.2x1").font(.system(size: 13, weight: .medium)).frame(width: 28, height: 26)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Split View Options")
        .padding(.leading, 8)
      }
      BarButton(systemName: "xmark", action: close).help("Close this Split Pane").padding(.leading, isFocused ? 4 : 0)
    }
    .overlay {
      // Shot 65: the domain darker than the buttons, black 65% or white 85%.
      Button(action: edit) {
        Label(tab.url.domain, systemImage: "link").font(.system(size: 13)).lineLimit(1).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(isLight ? .black.opacity(0.65) : .white.opacity(0.85))
      .padding(.horizontal, 100)
    }
    .contextMenu { options }
    // Shot 65: the buttons black 58% on a light page's bar, white 72% on a dark one's.
    .foregroundStyle(isLight ? .black.opacity(0.58) : .white.opacity(0.72))
    .padding(.leading, 7)
    .padding(.trailing, 8)
    .frame(height: 32)
    .background(color)
    // Shot 65: a hairline under the bar, black 4% on a light page, white 3% on a dark one.
    .overlay(alignment: .bottom) {
      Rectangle().fill(isLight ? .black.opacity(0.04) : .white.opacity(0.03)).frame(height: 1)
    }
    .task(id: tab.isLoading ? "" : tab.url.absoluteString) {
      pageColor = nil
      generation += 1
      let load = generation
      guard !tab.isLoading, let contents = Engine.shared.tabs[tab.id] else { return }
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      contents.snapshot { image in
        guard load == generation, let image, let color = Self.topColor(image) else { return }
        pageColor = color
      }
    }
  }

  @ViewBuilder private var options: some View {
    let index = panes.firstIndex(of: tab.id) ?? 0
    let split = space.split(of: tab.id)
    let isVertical = split?.isVertical == true
    Button("Add Split View", action: self.split).disabled(panes.count >= Space.maxPanes)
    Divider()
    Button(isVertical ? "Move Pane Up" : "Move Pane Left") { act(.movePane(tab.id, by: -1)) }.disabled(index == 0)
    Button(isVertical ? "Move Pane Down" : "Move Pane Right") { act(.movePane(tab.id, by: 1)) }
      .disabled(index == panes.count - 1)
    Toggle("Vertical Split", isOn: Binding { isVertical } set: { _ in split.map { act(.toggleVerticalSplit($0.id)) } })
    Divider()
    Toggle("Expand Current Split", isOn: Binding { isExpanded } set: { _ in expand() })
    Divider()
    Button("Separate Page from Split View") { act(.separate(tab.id)) }
    Button("Separate All Tabs") { split.map { act(.separateAll($0.id)) } }
  }

  // The page's color at its top edge: its top rows averaged into one pixel. A transparent or black result is
  // a pane that was not drawn (hidden or not yet painted), not a color.
  private static func topColor(_ image: NSImage) -> Color? {
    guard let page = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let strip = page.cropping(to: CGRect(x: 0, y: 0, width: page.width, height: min(page.height, 4)))
    else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
      data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(strip, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    guard pixel[3] > 250, Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) > 0 else { return nil }
    return Color(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
  }
}

struct BarButton: View {
  let systemName: String
  var isEnabled = true
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .medium))
        .frame(width: 28, height: 26)
        .background(isHovering && isEnabled ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Shot 65: a disabled arrow at about half an enabled one's strength, which disabling alone gives.
    .disabled(!isEnabled)
    .onHover { isHovering = $0 }
  }
}
