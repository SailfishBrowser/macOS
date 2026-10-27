import AudioToolbox
import ComposableArchitecture

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // Settings' sound effects toggle, on by default.
  static var soundEffects: Self { Self[.appStorage("soundEffects"), default: true] }
}

// The two interface sounds, which Settings > Advanced turns off: a chime when a download finishes and the
// shutter on a capture. Both come from the system's own sound set.
enum SoundEffect: CaseIterable, Sendable {
  case downloadComplete
  case capture

  // Registered with the system sound server at launch. The server plays them, so a play returns at once instead of
  // starting audio output on the main thread, which held the window still for several frames.
  private static let ids = Dictionary(uniqueKeysWithValues: allCases.map { effect in
    var id: SystemSoundID = 0
    AudioServicesCreateSystemSoundID(effect.file as CFURL, &id)
    return (effect, id)
  })

  static func register() { _ = ids }

  @MainActor static func play(_ effect: SoundEffect) {
    @Shared(.soundEffects) var soundEffects
    guard soundEffects else { return }
    AudioServicesPlaySystemSound(ids[effect]!)
  }

  private var file: URL {
    switch self {
    case .downloadComplete: URL(filePath: "/System/Library/Sounds/Glass.aiff")
    case .capture:
      URL(filePath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif")
    }
  }
}

struct SoundEffectsClient: Sendable {
  var play: @Sendable (SoundEffect) async -> Void
}

extension SoundEffectsClient: DependencyKey {
  static let liveValue = Self(play: { effect in await SoundEffect.play(effect) })
  static let testValue = Self(play: { _ in })
}

extension DependencyValues {
  var soundEffects: SoundEffectsClient {
    get { self[SoundEffectsClient.self] }
    set { self[SoundEffectsClient.self] = newValue }
  }
}
