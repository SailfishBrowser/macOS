import AppKit
import SwiftUI

// The tooltip pill: dark navy, used by the tab-row tooltip and the space dot's tip.
extension View {
  func tooltipPill() -> some View {
    background(Color(hex: 0x0A0D4B), in: Capsule())
  }
}

// The tooltip: the pill under the pointer after about a second of hover. Any click, scroll or key while a row
// is hovered cancels it, before or after it shows. One panel serves the whole app.
@MainActor
private enum TooltipPanel {
  static let panel: NSPanel = {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    return panel
  }()
  // Bumped by every click, scroll or key, so a pending tooltip knows to stay hidden.
  static var generation = 0
  private static var monitor: Any?
  private static var armed = 0

  // Watches for the events that cancel a tooltip while any row with one is hovered.
  static func arm() {
    armed += 1
    monitor = monitor ?? NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
    ) { event in
      generation += 1
      hide()
      return event
    }
  }

  static func disarm() {
    armed -= 1
    hide()
    guard armed == 0 else { return }
    monitor.map(NSEvent.removeMonitor)
    monitor = nil
  }

  static func show(_ content: some View, at point: NSPoint, over window: NSWindow) {
    let host = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
    let size = host.fittingSize
    panel.contentView = host
    // Below the pointer's tip.
    panel.setFrame(NSRect(x: point.x, y: point.y - 22 - size.height, width: size.width, height: size.height), display: true)
    if panel.parent != window {
      panel.parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
    }
    panel.orderFront(nil)
  }

  static func hide() {
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }
}

private struct HoverTooltip: ViewModifier {
  let title: String
  let subtitle: String?
  let isEnabled: Bool
  // Set from the pointer's arrival until it leaves, so a tooltip shows at most once per hover.
  @State private var pending: Task<Void, Never>?

  func body(content: Content) -> some View {
    content
      .onContinuousHover { phase in
        switch phase {
        case .active:
          guard isEnabled, pending == nil else { return }
          TooltipPanel.arm()
          let generation = TooltipPanel.generation
          pending = Task {
            try? await Task.sleep(for: .seconds(1))
            // Not over another window a click just brought up, such as Settings from Tidy.
            guard !Task.isCancelled, TooltipPanel.generation == generation, let window = NSApp.keyWindow,
              window.frame.contains(NSEvent.mouseLocation), NSEvent.pressedMouseButtons == 0
            else { return }
            TooltipPanel.show(label, at: NSEvent.mouseLocation, over: window)
          }
        case .ended:
          leave()
        }
      }
      .onDisappear { leave() }
  }

  private func leave() {
    guard let pending else { return }
    pending.cancel()
    self.pending = nil
    TooltipPanel.disarm()
  }

  private var label: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
      if let subtitle {
        Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
      }
    }
    .lineLimit(1)
    .frame(maxWidth: 320, alignment: .leading)
    .fixedSize()
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .tooltipPill()
  }
}

extension View {
  // The app's tooltip, for rows where the system's own would show.
  func hoverTooltip(_ title: String, subtitle: String? = nil, isEnabled: Bool = true) -> some View {
    modifier(HoverTooltip(title: title, subtitle: subtitle, isEnabled: isEnabled))
  }
}
