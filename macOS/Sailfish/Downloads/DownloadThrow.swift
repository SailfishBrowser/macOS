import AppKit
import ComposableArchitecture
import SwiftUI

// A window's thrown download glyphs, and the frames they fly between in the window's coordinate space.
@Observable final class DownloadThrows {
  static let space = "DownloadThrows"
  var page: CGRect = .zero
  // The Library button's badge, where a thrown glyph lands.
  var badge: CGRect = .zero
  var flights: IdentifiedArrayOf<Flight> = []
  // Running downloads that are not to be thrown again: those running when the window opened and those that have landed.
  var arrived: Set<Download.ID> = []

  struct Flight: Identifiable {
    let id: Download.ID
    let from: CGPoint
    let to: CGPoint
  }
}

// The download throw: a new download's glyph appears under the pointer, or near the page's top right corner when
// the pointer is outside the window, and is thrown onto the Library button's badge. Only the key window throws, and only while its
// sidebar and Library button show.
struct DownloadThrowLayer: View {
  let canThrow: Bool
  @Environment(DownloadThrows.self) private var downloadThrows
  @Environment(StoreOf<DownloadsFeature>.self) private var downloads
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    let running = Set(downloads.downloads.filter { $0.state == .inProgress }.ids)
    ZStack(alignment: .topLeading) {
      ForEach(downloadThrows.flights) { flight in
        ThrownGlyph(flight: flight) {
          downloadThrows.flights.remove(id: flight.id)
          downloadThrows.arrived.insert(flight.id)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .allowsHitTesting(false)
    .onChange(of: running, initial: true) { old, new in
      for id in new.subtracting(downloadThrows.arrived) where downloadThrows.flights[id: id] == nil {
        if !old.contains(id), canThrow, controlActiveState == .key, Motion.downloadThrow.flight != nil {
          downloadThrows.flights.append(DownloadThrows.Flight(
            id: id, from: origin(), to: CGPoint(x: downloadThrows.badge.midX, y: downloadThrows.badge.midY)))
        } else {
          downloadThrows.arrived.insert(id)
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
