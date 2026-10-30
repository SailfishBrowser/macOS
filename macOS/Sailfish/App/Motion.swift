import AppKit
import SwiftUI

// The motion presets. SwiftUI's spring bounce is 1 minus the damping ratio. With Reduce Motion on, each one is
// nil, so the change lands at once; the setting is read whenever a preset is used, so it applies without a relaunch.
@MainActor
enum Motion {
  // The layout move: the space switch, the Library and the rest. Every recorded frame of a space switch lies on
  // this critically damped spring from rest, 3 pt RMS over 13 recorded switches:
  // 197, 155, 113, 87, 60, 41, 27, 18, 12, 8, 5, 3, 2, 1 pt to go of 219, at rest after 15-16 frames, the same
  // curve as its swipe settle. A recorded switch's first frame often came 1-6 frames late, so it shows up 60-80% of the
  // way; a held duplicate frame comes with it. The Library's 1198, 454, 214, 142, 94, 60 pt is that spring from
  // its fifth frame on. Retargeted in flight, the spring keeps its velocity.
  static var layout: Animation? { motion(.spring(duration: 0.2, bounce: 0)) }
  // The spaces' strip settling once the fingers lift off a swipe. Recorded over eleven swipes:
  // the strip starts from rest whatever the fingers' speed, eases in and lands with no overshoot after 15-18 frames,
  // which is a critically damped spring of 0.2 s (2 px off the frames on average).
  static var swipeSettle: Animation? { motion(Animation(RestingSpring(duration: 0.2))) }
  // The strip following the fingers during a swipe: each move eases in over about a frame, so it reads as 1:1, and a
  // swipe begun while the strip still settles adds to that settle instead of cutting or hurrying it.
  static var swipeTrack: Animation? { motion(Animation(RestingSpring(duration: 0.05))) }
  // Rows making room or closing up. Recorded at 60 fps (⌘W 41 and 31 pt, ⌘T 41,
  // Clear 17 twice): 24, 14, 7, 3, 1 pt to go after ⌘W, at rest in 5 frames. This spring fits all five within 0.32 pt
  // RMS, each from its own sub-frame start (0.115 s: 0.73 pt), as does the third-party 120 fps figure.
  static var row: Animation? { motion(.spring(duration: 0.13, bounce: 0.1)) }
  // ⌘S hides or docks the sidebar. A Retina recording (seven hides, seven shows of a
  // 291 pt sidebar, normalized per toggle): hide 0.42 0.71 0.88 0.97 1.00 and show 0.28 0.62 0.84 0.95 1.00 of
  // the travel frame by frame, at rest by frame 5 with a finite end slope. These curves fit both within 0.01.
  // The earlier ease-out quart ended asymptotically, so at 2x its last 1% (6 px) crawled over two or three frames.
  // A hide waits two frames: the page is resized to its wider width at once, behind the card's clip, and the engine
  // has drawn it by the time the card moves. The first moving frame should already show the wider layout; without the
  // wait ours showed the old, narrower page with a blank strip beside it for two frames.
  static var sidebarHide: Animation? { motion(.timingCurve(0, 0.4, 0.3, 1, duration: 0.083).delay(2.0 / 60)) }
  static var sidebarShow: Animation? { motion(.timingCurve(0.25, 0.85, 0.7, 1, duration: 0.083)) }
  // The hidden sidebar's card sliding in from the window's edge. Recorded at 60 fps (two passes,
  // the card's trailing edge): 206, 147, 93, 51, 24, 8 and 0 pt to go frame by frame, 4 pt past rest for 8 frames, at
  // rest after 14-15 frames; this spring fits both passes within 0.9 pt (the third-party 120 fps figure, 0.175 s at
  // damping 0.8, agrees).
  static var peek: Animation? { motion(.spring(duration: 0.17, bounce: 0.2)) }
  // The card sliding back out once the pointer leaves it: gone 5 frames after it starts in the recording (270, 220, 161, 109,
  // 71 pt from the window's edge) and in this spring.
  static var peekOut: Animation? { motion(.spring(duration: 0.15, bounce: 0.22)) }
  // A tab row or favorite giving while the mouse is down and springing back on release. Recorded at 60 fps
  // (2026-10-27, rows, pinned rows and tiles): the same spring both ways, 18% past its target about 100 ms in and at
  // rest by 250 ms; this spring fits three presses and releases within 1.4% of the travel.
  static var press: Animation? { motion(.spring(response: 0.2, dampingFraction: 0.49)) }
  // The first launch's app icon growing in on black; not measured, as Arc's intro is unrecorded.
  static var intro: Animation? { motion(.spring(duration: 0.5, bounce: 0.2)) }
  // The footer's "+" menu scaling in from its corner; not measured.
  static var menu: Animation? { motion(.spring(duration: 0.18, bounce: 0.15)) }
  // A fresh space's New Tab label breathing until its first tab; not measured.
  static var pulse: Animation? { motion(.easeInOut(duration: 0.9)) }
  // A dragged row's copy settling, into its slot on drop or back onto its row when the drop is rejected: it eases
  // over about 17 frames, nearly linear at first and slowing at the end.
  static var land: Animation? { motion(.timingCurve(0.2, 0.4, 0.7, 1, duration: 0.28)) }
  // The list crossfading into a new split: about 6 frames.
  static var fade: Animation? { motion(.linear(duration: 0.1)) }
  // A dragged tab resting on another tab's row waits this long before the row shows the half it will split into:
  // 13 frames both times in a recording, of which about one is the frame being drawn.
  static let splitDwell: Duration = .milliseconds(195)
  // On release the split half flashes solid for 4 frames, then the row shows plain for 3 before the split forms.
  static let splitFlash: Duration = .milliseconds(67)
  static let splitPause: Duration = .milliseconds(50)
  // The load dash above the page, fading in and out over a 1.6 s cycle while the page is awaited.
  static var loadPulse: Animation? { motion(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) }
  // The zoom indicator's fade: in over about 10 frames, out over about 4.
  static var zoomIndicatorIn: Animation? { motion(.easeInOut(duration: 0.165)) }
  static var zoomIndicatorOut: Animation? { motion(.easeOut(duration: 0.075)) }
  // The download stack's rows rising out of the Library button: a recorded clip (frames 1378-1387)
  // fits a critically damped spring of response 0.1 s, for the rows' offsets and their opacity alike.
  static var downloadStack: Animation? { motion(.spring(response: 0.1, dampingFraction: 1)) }

  // A new download's glyph thrown from the pointer onto the Library button's badge. A recorded clip of a
  // download at 60 fps (2026-10-26, frames 1198-1284): the glyph shows where it starts for 3 frames as it fades in
  // (1199-1201), then moves across at an even speed and lands 52 frames later, its height a parabola whose top comes
  // 11 frames in whatever the distance. It grows from 35 to 48 pt by the top and shrinks evenly to 12 pt on landing,
  // then goes at once. The badge fades in over 3 frames; on completion the file's icon replaces it, drawn 1.5 times
  // its size for one frame and at its size the next (1283-1284), with no step between.
  struct DownloadThrow {
    let duration: Double
    let apexTime: Double
    let fadeIn: Double
    let startSize: CGFloat
    let apexSize: CGFloat
    let landedSize: CGFloat
    let badgeFade: Double
    let iconPop: CGFloat
    let iconPopDuration: Double
    // Where the glyph starts when the pointer is outside the window: this far in from the page's top right corner.
    let cornerInset: CGFloat

    // Time itself, so the path's own shape sets the motion, starting once the glyph has faded in; nil with Reduce
    // Motion, which skips the throw.
    @MainActor var flight: Animation? { motion(.linear(duration: duration).delay(fadeIn)) }
    @MainActor var appear: Animation? { motion(.linear(duration: fadeIn)) }
    @MainActor var badge: Animation? { motion(.linear(duration: badgeFade)) }
    @MainActor var pop: Animation? { motion(.linear(duration: iconPopDuration)) }
  }

  static let downloadThrow = DownloadThrow(
    duration: 52.0 / 60, apexTime: 11.0 / 60, fadeIn: 3.0 / 60, startSize: 35, apexSize: 48, landedSize: 12,
    badgeFade: 3.0 / 60, iconPop: 1.5, iconPopDuration: 1.0 / 60, cornerInset: 48)

  private static func motion(_ animation: Animation) -> Animation? {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
  }
}

// Critically damped springs that always start from rest and add up. A new one on a value still moving under another
// keeps the old one running and adds its own change as a further spring: the swipe settle takes none of the fingers'
// speed, and the fingers' moves add to a settle still running instead of cutting or hurrying it.
private struct RestingSpring: CustomAnimation {
  private let omega: Double

  init(duration: Double) {
    omega = 2 * Double.pi / duration
  }

  func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
    // A new target, at the start or merged in, adds the change as a part of its own from that moment.
    let change = value - context.springs.parts.reduce(context.springs.done) { $0 + $1.change }
    if change.magnitudeSquared > 0 {
      context.springs.parts.append(RestingPart(start: context.springs.merged ?? 0, change: change, omega: omega))
    }
    context.springs.merged = nil
    // A part is done once under a thousandth of its change remains (18 frames at 0.2 s); a drag adds one a move, so
    // done parts fold into one sum.
    for part in context.springs.parts where part.left(at: time) < 1e-3 { context.springs.done += part.change }
    context.springs.parts.removeAll { $0.left(at: time) < 1e-3 }
    if context.springs.parts.isEmpty { return nil }
    return context.springs.parts.reduce(context.springs.done) { $0 + $1.change.scaled(by: 1 - $1.left(at: time)) }
  }

  func velocity<V: VectorArithmetic>(value: V, time: TimeInterval, context: AnimationContext<V>) -> V? {
    context.springs.parts.reduce(V.zero) { $0 + $1.change.scaled(by: $1.rate(at: time)) }
  }

  func shouldMerge<V: VectorArithmetic>(
    previous: Animation, value: V, time: TimeInterval, context: inout AnimationContext<V>
  ) -> Bool {
    guard previous.base is Self else { return false }
    context.springs.merged = time
    return true
  }
}

private struct RestingPart<V: VectorArithmetic> {
  var start: TimeInterval
  var change: V
  var omega: Double

  // The fraction of the change still to go, and how fast it goes.
  func left(at time: TimeInterval) -> Double {
    let x = omega * max(time - start, 0)
    return (1 + x) * exp(-x)
  }

  func rate(at time: TimeInterval) -> Double {
    let t = max(time - start, 0)
    return omega * omega * t * exp(-omega * t)
  }
}

private struct RestingParts<V: VectorArithmetic>: AnimationStateKey {
  var done = V.zero
  var parts: [RestingPart<V>] = []
  // When the latest animation merged in, for the part its change starts.
  var merged: TimeInterval?
  static var defaultValue: Self { .init() }
}

extension AnimationContext {
  fileprivate var springs: RestingParts<Value> {
    get { state[RestingParts<Value>.self] }
    set { state[RestingParts<Value>.self] = newValue }
  }
}
