import AppKit
import SwiftUI

// The first launch's opening, over the window only: the app icon fades and grows in on black, holds, then flies to the
// onboarding dialog's icon, and the dialog fades in around it as the black fades to the window. The dialog's sheet is a
// window of its own above this one. It comes down at once, invisible, and the icon flies to where it really is, since
// macOS 15 hangs a sheet from the title bar and macOS 26 centers it in the window. macOS dims a window behind its
// sheet, which leaves the black black, so only the icon is drawn above both, in a panel of its own.
struct FirstLaunchIntro: View {
  let land: () -> Void
  let end: () -> Void
  @State private var intro = IntroModel()
  @State private var window: NSWindow?
  @State private var panel: NSPanel?

  var body: some View {
    Color.black.opacity(intro.phase == .gone ? 0 : 1)
      .ignoresSafeArea()
      .allowsHitTesting(intro.phase != .gone)
      .background(WindowReader { window = $0 })
      // The panel covers the window, so a resize during the intro moves the icon with it.
      .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
        if let window { panel?.setFrame(window.frame, display: true) }
      }
      .task {
        while window == nil {
          guard (try? await Task.sleep(for: .milliseconds(16))) != nil else { return }
        }
        let panel = Self.panel(over: window!, intro: intro)
        self.panel = panel
        defer {
          window?.removeChildWindow(panel)
          panel.close()
        }
        withAnimation(Motion.intro) { intro.phase = .shown }
        try? await Task.sleep(for: .seconds(0.9))
        while window?.attachedSheet == nil {
          guard (try? await Task.sleep(for: .milliseconds(16))) != nil else { return }
        }
        let corner = Self.icon(of: window!.attachedSheet!, in: window!)
        withAnimation(Motion.layout) { intro.corner = corner }
        try? await Task.sleep(for: .seconds(0.25))
        land()
        try? await Task.sleep(for: .seconds(0.3))
        withAnimation(Motion.layout) { intro.phase = .gone }
        try? await Task.sleep(for: .seconds(0.3))
        end()
      }
  }

  // The center of the dialog's 48 pt icon, from the window's top left.
  private static func icon(of sheet: NSWindow, in window: NSWindow) -> CGPoint {
    let inset = ImportView.padding + 24
    return CGPoint(x: sheet.frame.minX - window.frame.minX + inset, y: window.frame.maxY - sheet.frame.maxY + inset)
  }

  // A clear, borderless panel over the window that draws the icon above the sheet; it lets clicks through and hides
  // when Sailfish is no longer the active app.
  private static func panel(over window: NSWindow, intro: IntroModel) -> NSPanel {
    let panel = NSPanel(
      contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = true
    panel.level = .floating
    panel.contentView = NSHostingView(rootView: IntroIcon(intro: intro))
    window.addChildWindow(panel, ordered: .above)
    return panel
  }
}

@MainActor @Observable private final class IntroModel {
  enum Phase {
    case dark, shown, gone
  }

  var phase = Phase.dark
  // Where the dialog's icon is, once the icon flies there.
  var corner: CGPoint?
}

// The icon grows in at the window's center and flies to the dialog's corner, where it stays over the dialog's own icon
// until the panel closes.
private struct IntroIcon: View {
  let intro: IntroModel

  var body: some View {
    GeometryReader { proxy in
      Image(nsImage: NSApp.applicationIconImage).resizable()
        .frame(width: intro.corner == nil ? 128 : 48, height: intro.corner == nil ? 128 : 48)
        .scaleEffect(intro.phase == .dark ? 0.85 : 1)
        .opacity(intro.phase == .dark ? 0 : 1)
        .position(intro.corner ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2))
    }
  }
}

// Hands over the window a view is in, as soon as it is in one.
struct WindowReader: NSViewRepresentable {
  let found: (NSWindow) -> Void

  func makeNSView(context: Context) -> ReaderView {
    let view = ReaderView()
    view.found = found
    return view
  }

  func updateNSView(_ view: ReaderView, context: Context) {}

  final class ReaderView: NSView {
    var found: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window.map { found?($0) }
    }
  }
}
