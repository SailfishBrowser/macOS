import AppKit
import ComposableArchitecture
import SwiftUI

// A window's thrown download glyphs, and the frames they fly between in the window's coordinate space.
@MainActor @Observable final class DownloadThrows {
  nonisolated static let space = "DownloadThrows"
  var page: CGRect = .zero
  // The Library button's badge, where a thrown glyph lands.
  var badge: CGRect = .zero
  var flights: IdentifiedArrayOf<Flight> = []
  // Running downloads that are not to be thrown again: those running when the window opened and those that have landed.
  var arrived: Set<Download.ID> = []
  // The Library button out on its own in the window's bottom left corner, for a throw while the sidebar is hidden.
  var dock: Dock = .away
  // Downloads waiting for the docked button to finish sliding in, with where each glyph starts.
  private var waiting: [Download.ID: CGPoint] = [:]
  private var undock: Task<Void, Never>?

  enum Dock { case away, sliding, out }

  struct Flight: Identifiable {
    let id: Download.ID
    let from: CGPoint
    let to: CGPoint
  }

  func isThrowing(_ id: Download.ID) -> Bool { flights[id: id] != nil || waiting[id] != nil }

  // Throws a glyph onto the badge where it is now.
  func launch(_ id: Download.ID, from: CGPoint) {
    flights.append(Flight(id: id, from: from, to: CGPoint(x: badge.midX, y: badge.midY)))
  }

  // Slides the docked button in, if it is not out already, and throws once it has come to rest on its own badge.
  func launchDocked(_ id: Download.ID, from: CGPoint) {
    undock?.cancel()
    if dock == .out { return launch(id, from: from) }
    waiting[id] = from
    guard dock == .away else { return }
    withAnimation(Motion.peek, completionCriteria: .logicallyComplete) { dock = .sliding } completion: { [self] in
      dock = .out
      for (id, from) in waiting { launch(id, from: from) }
      waiting = [:]
    }
  }

  func land(_ id: Download.ID) {
    flights.remove(id: id)
    arrived.insert(id)
    // The docked button stays a moment once the last glyph is on it, so its badge is seen, then slides away.
    guard dock != .away, flights.isEmpty, waiting.isEmpty else { return }
    undock?.cancel()
    undock = Task { [self] in
      guard (try? await Task.sleep(for: .seconds(Motion.downloadThrow.dockHold))) != nil else { return }
      withAnimation(Motion.downloadThrow.dockOut) { dock = .away }
    }
  }
}

// While the sidebar is hidden, the Library button alone on a card like the peeked sidebar's, in the window's bottom
// left corner, so a thrown download has somewhere to land.
struct LibraryDock: View {
  let fill: AnyShapeStyle
  let action: () -> Void
  @State private var hover = LibraryHover()

  var body: some View {
    // The badge sits on the card's top right corner, as on an app icon, clear of the glyph: the button is 10 pt in
    // from the card's sides and 11 pt down from its top, so that corner is 10 pt right of the button and 11 pt above it.
    LibraryButton(hover: hover, badgeOffset: CGSize(width: 20, height: -21), action: action)
      .padding(.horizontal, 10)
      .frame(height: 50)
      .background(fill, in: RoundedRectangle(cornerRadius: 10))
      .background(.regularMaterial.shadow(.drop(color: .black.opacity(0.4), radius: 12)), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.floatingRim))
      .coversPage()
      // Clear of the window's bottom left corner.
      .padding(6)
      .padding([.leading, .bottom], 30)
  }
}

// The download throw: a new download's glyph appears under the pointer, or near the page's top right corner when
// the pointer is outside the window, and is thrown onto the Library button's badge. Only the key window throws. With
// the sidebar hidden, the Library button slides in on its own first and the glyph is thrown onto it.
struct DownloadThrowLayer: View {
  // The sidebar and its Library button show.
  let canThrow: Bool
  // The sidebar is hidden, and the Library button can come out on its own.
  let canDock: Bool
  @Environment(DownloadThrows.self) private var downloadThrows
  @Environment(StoreOf<DownloadsFeature>.self) private var downloads
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    let running = Set(downloads.downloads.filter { $0.state == .inProgress }.ids)
    ZStack(alignment: .topLeading) {
      ForEach(downloadThrows.flights) { flight in
        ThrownGlyph(flight: flight) { downloadThrows.land(flight.id) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .allowsHitTesting(false)
    .onChange(of: running, initial: true) { old, new in
      for id in new.subtracting(downloadThrows.arrived) where !downloadThrows.isThrowing(id) {
        guard !old.contains(id), canThrow || canDock, controlActiveState == .key, Motion.downloadThrow.flight != nil
        else {
          downloadThrows.arrived.insert(id)
          continue
        }
        if canThrow {
          downloadThrows.launch(id, from: origin())
        } else {
          downloadThrows.launchDocked(id, from: origin())
        }
      }
    }
  }

  private func origin() -> CGPoint {
    let window = NSApp.keyWindow!
    let pointer = window.mouseLocationOutsideOfEventStream
    // The content view fills the window, whose base coordinates rise from the bottom.
    let point = CGPoint(x: pointer.x, y: window.frame.height - pointer.y)
    let inset = Motion.downloadThrow.cornerInset
    return CGRect(origin: .zero, size: window.frame.size).contains(point)
      ? point : CGPoint(x: downloadThrows.page.maxX - inset, y: downloadThrows.page.minY + inset)
  }
}

// The thrown glyph: a thin ring around a down arrow, light grey on a dark disc.
private struct ThrownGlyph: View {
  let flight: DownloadThrows.Flight
  let land: () -> Void
  @State private var time: Double = 0
  @State private var isShown = false

  var body: some View {
    let shape = Motion.downloadThrow
    Image(systemName: "arrow.down.circle")
      .resizable()
      .fontWeight(.light)
      .foregroundStyle(.white.opacity(0.7))
      .background(Circle().fill(.black.opacity(0.3)))
      .frame(width: shape.apexSize, height: shape.apexSize)
      .opacity(isShown ? 1 : 0)
      .modifier(Projectile(time: time, from: flight.from, to: flight.to, shape: shape))
      .onAppear {
        withAnimation(shape.appear) { isShown = true }
        withAnimation(shape.flight, completionCriteria: .logicallyComplete) { time = shape.duration } completion: {
          land()
        }
      }
  }
}

// The measured path: across at an even speed, and down a parabola that tops out at the apex time, so the top's
// height follows from the drop. The size rises evenly to its largest at the top and falls evenly to its landed size.
private struct Projectile: GeometryEffect {
  var time: Double
  let from: CGPoint
  let to: CGPoint
  let shape: Motion.DownloadThrow

  nonisolated var animatableData: Double {
    get { time }
    set { time = newValue }
  }

  nonisolated func effectValue(size: CGSize) -> ProjectionTransform {
    let t = time, total = shape.duration, apex = shape.apexTime
    let x = from.x + (to.x - from.x) * t / total
    let y = from.y + (to.y - from.y) * (t * t - 2 * apex * t) / (total * total - 2 * apex * total)
    let side =
      t < apex
      ? shape.startSize + (shape.apexSize - shape.startSize) * t / apex
      : shape.apexSize + (shape.landedSize - shape.apexSize) * (t - apex) / (total - apex)
    let scale = side / size.width
    return ProjectionTransform(
      CGAffineTransform(translationX: x - side / 2, y: y - side / 2).scaledBy(x: scale, y: scale))
  }
}
