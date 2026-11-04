import AppKit
import SwiftUI

@MainActor final class HoverTracker {
  private struct Region {
    var frame: CGRect
    var clip: UUID?
    var layer: Int
    var isEnabled: Bool
    let hover: (Bool) -> Void
  }

  private var regions: [UUID: Region] = [:]
  private var clips: [UUID: CGRect] = [:]
  private var hovered: Set<UUID> = []
  private var locations: [ObjectIdentifier: CGPoint] = [:]
  private var isResolvePending = false

  func move(_ area: NSView, to location: CGPoint?) {
    locations[ObjectIdentifier(area)] = location
    resolve()
  }

  func set(_ id: UUID, frame: CGRect, clip: UUID?, layer: Int, isEnabled: Bool, hover: @escaping (Bool) -> Void) {
    regions[id] = Region(frame: frame, clip: clip, layer: layer, isEnabled: isEnabled, hover: hover)
    regionsChanged()
  }

  func enable(_ id: UUID, _ isEnabled: Bool) {
    regions[id]?.isEnabled = isEnabled
    regionsChanged()
  }

  func remove(_ id: UUID) {
    regions[id] = nil
    hovered.remove(id)
    regionsChanged()
  }

  func clip(_ id: UUID, _ frame: CGRect?) {
    clips[id] = frame
    regionsChanged()
  }

  private func regionsChanged() {
    guard !locations.isEmpty, !isResolvePending else { return }
    isResolvePending = true
    DispatchQueue.main.async { [self] in
      isResolvePending = false
      resolve()
    }
  }

  private func resolve() {
    let under = locations.values.first.map { point in
      regions.filter { _, region in
        region.isEnabled && region.frame.contains(point) && region.clip.map { clips[$0]?.contains(point) == true } != false
      }
    } ?? [:]
    let top = under.values.map(\.layer).max()
    let now = Set(under.filter { $0.value.layer == top }.keys)
    let left = hovered.subtracting(now)
    let entered = now.subtracting(hovered)
    hovered = now
    for id in left { regions[id]?.hover(false) }
    for id in entered { regions[id]?.hover(true) }
  }
}

struct HoverTrackingArea: NSViewRepresentable {
  let tracker: HoverTracker

  func makeNSView(context: Context) -> TrackingView { TrackingView(tracker: tracker) }

  func updateNSView(_ view: TrackingView, context: Context) {}

  final class TrackingView: NSView {
    let tracker: HoverTracker
    private var dragMonitor: Any?

    init(tracker: HoverTracker) {
      self.tracker = tracker
      super.init(frame: .zero)
      addTrackingArea(
        NSTrackingArea(
          rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { report(event) }

    override func mouseMoved(with event: NSEvent) { report(event) }

    override func mouseExited(with event: NSEvent) { tracker.move(self, to: nil) }

    override func viewDidMoveToWindow() {
      dragMonitor.map(NSEvent.removeMonitor)
      dragMonitor = nil
      guard window != nil else { return tracker.move(self, to: nil) }
      (window as? BrowserWindow)?.pointerTrackers.add(self)
      dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
        if let self, event.window === window { report(event) }
        return event
      }
    }

    private func report(_ event: NSEvent) {
      let isInside = bounds.contains(convert(event.locationInWindow, from: nil))
      let isCovered = (window as? BrowserWindow).map {
        $0.isCovered(event.locationInWindow, sidebar: true) || $0.isOnColumnResizeArea(event.locationInWindow)
      } == true
      tracker.move(self, to: isInside && !isCovered ? window?.contentView?.convert(event.locationInWindow, from: nil) : nil)
    }
  }
}

private struct HoverRegion: ViewModifier {
  let hover: (Bool) -> Void
  @Environment(\.hoverTracker) private var tracker
  @Environment(\.hoverClip) private var clip
  @Environment(\.hoverLayer) private var layer
  @Environment(\.isHoverable) private var isHoverable
  @State private var id = UUID()
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
        tracker?.set(id, frame: frame, clip: clip, layer: layer, isEnabled: isHoverable) { isHovered = $0 }
      }
      .onChange(of: isHoverable) { _, isHoverable in tracker?.enable(id, isHoverable) }
      .onChange(of: isHovered) { _, isHovered in hover(isHovered) }
      .onDisappear { tracker?.remove(id) }
  }
}

private struct HoverClip: ViewModifier {
  @Environment(\.hoverTracker) private var tracker
  @State private var id = UUID()

  func body(content: Content) -> some View {
    content
      .environment(\.hoverClip, id)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tracker?.clip(id, $0) }
      .onDisappear { tracker?.clip(id, nil) }
  }
}

extension EnvironmentValues {
  @Entry var hoverTracker: HoverTracker?
  @Entry var hoverClip: UUID?
  @Entry var hoverLayer = 0
  @Entry var isHoverable = true
}

extension View {
  func hoverRegion(_ hover: @escaping (Bool) -> Void) -> some View {
    modifier(HoverRegion(hover: hover))
  }

  func hoverClip() -> some View {
    modifier(HoverClip())
  }

  func hitTesting(_ isEnabled: Bool) -> some View {
    allowsHitTesting(isEnabled).transformEnvironment(\.isHoverable) { $0 = $0 && isEnabled }
  }
}
