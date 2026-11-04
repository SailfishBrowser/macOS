import AppKit
import SwiftUI

final class WindowHostingView<Content: View>: NSHostingView<Content> {
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard NSApp.currentEvent?.type == .scrollWheel, let superview,
      let container = (window as? BrowserWindow)?.page(at: superview.convert(point, to: nil)),
      let host = container.superview
    else { return super.hitTest(point) }
    return container.hitTest(host.convert(point, from: superview))
  }
}

private struct Cover: NSViewRepresentable {
  let isOverSidebar: Bool

  func makeNSView(context: Context) -> CoverView { CoverView(isOverSidebar: isOverSidebar) }

  func updateNSView(_ view: CoverView, context: Context) {}
}

final class CoverView: NSView {
  let isOverSidebar: Bool

  init(isOverSidebar: Bool) {
    self.isOverSidebar = isOverSidebar
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    (window as? BrowserWindow)?.covers.add(self)
  }
}

extension View {
  func coversPage() -> some View {
    background(Cover(isOverSidebar: false))
  }

  func coversWindow() -> some View {
    background(Cover(isOverSidebar: true))
  }
}
