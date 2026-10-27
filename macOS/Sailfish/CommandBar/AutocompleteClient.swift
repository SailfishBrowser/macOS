import ComposableArchitecture
@preconcurrency import EngineCore

struct AutocompleteMatch: Equatable, Sendable {
  var contents: String
  var description: String
  var url: URL
  var type: ECAutocompleteMatchType
  // The rest of the default match's text, shown selected after what was typed.
  var inlineAutocompletion = ""
  // The site search the match offers with Tab, e.g. "wikipedia.org" and "Wikipedia (en)".
  var keyword: String?
  var keywordName: String?
}

@DependencyClient
struct AutocompleteClient: Sendable {
  // The matches for `text`, best first, until Chrome is done with it or a newer query starts. One requested
  // before the last started finishes at once, since effects can start out of order.
  var query: @Sendable (
    _ profile: UUID, _ incognito: Bool, _ text: String, _ keyword: String?, _ requested: ContinuousClock.Instant
  ) async -> AsyncStream<[AutocompleteMatch]> = { _, _, _, _, _ in .finished }
  var select: @Sendable (_ profile: UUID, _ incognito: Bool, _ url: URL) async -> Void
  // The favicon history keeps for a page, or else the one imported with it, nil for none.
  var favicon: @Sendable (_ profile: UUID, _ incognito: Bool, _ url: URL) async -> NSImage?
}

extension AutocompleteClient: TestDependencyKey {
  static let testValue = Self()
}

extension DependencyValues {
  var autocomplete: AutocompleteClient {
    get { self[AutocompleteClient.self] }
    set { self[AutocompleteClient.self] = newValue }
  }
}

extension AutocompleteClient: DependencyKey {
  static let liveValue = Self(
    query: { await Autocomplete.of($0, $1).query($2, keyword: $3, requested: $4) },
    select: { profile, incognito, url in await Autocomplete.of(profile, incognito).select(url) },
    favicon: { await Autocomplete.favicon($0, $1, $2) }
  )
}

@MainActor
final class Autocomplete: NSObject, @preconcurrency ECAutocompleteDelegate {
  private static var all: [ECBrowserContext: Autocomplete] = [:]
  private let autocomplete: ECAutocomplete
  private var matches: [ECAutocompleteMatch] = []
  private var continuation: AsyncStream<[AutocompleteMatch]>.Continuation?
  private var generation = 0
  private var started: ContinuousClock.Instant?

  static func of(_ profile: UUID, _ incognito: Bool) async -> Autocomplete {
    let profile = await Engine.shared.context(profile)
    let context = incognito ? profile.offTheRecord : profile
    if let autocomplete = all[context] { return autocomplete }
    let autocomplete = Autocomplete(context)
    all[context] = autocomplete
    return autocomplete
  }

  // An imported page's icon from its browser comes first: Chrome's favicon service gives a page that redirected, as
  // to a sign-in page, the icon of where it landed. Chrome's favicon service runs on the main thread.
  static func favicon(_ profile: UUID, _ incognito: Bool, _ url: URL) async -> NSImage? {
    if let imported = ImportedFavicons.image(url) { return imported }
    let profile = await Engine.shared.context(profile)
    let context = incognito ? profile.offTheRecord : profile
    return await withCheckedContinuation { continuation in
      context.favicon(forPageURL: url) { continuation.resume(returning: $0) }
    }
  }

  // Drops the autocomplete of a context that is closing.
  static func forget(_ context: ECBrowserContext) {
    all[context] = nil
  }

  private init(_ context: ECBrowserContext) {
    autocomplete = ECAutocomplete(browserContext: context)
    super.init()
    autocomplete.delegate = self
  }

  func query(_ text: String, keyword: String?, requested: ContinuousClock.Instant) -> AsyncStream<[AutocompleteMatch]> {
    let (stream, continuation) = AsyncStream.makeStream(of: [AutocompleteMatch].self)
    guard started.map({ requested > $0 }) ?? true else {
      continuation.finish()
      return stream
    }
    started = requested
    generation += 1
    let generation = generation
    continuation.onTermination = { _ in
      Task { @MainActor in
        if self.generation == generation { self.autocomplete.stop() }
      }
    }
    self.continuation?.finish()
    self.continuation = continuation
    autocomplete.start(withText: text, keyword: keyword)
    return stream
  }

  func select(_ url: URL) {
    matches.first { $0.destinationURL == url }.map(autocomplete.didSelect)
  }

  func autocomplete(_ autocomplete: ECAutocomplete, didUpdateMatches matches: [ECAutocompleteMatch], done: Bool) {
    self.matches = matches
    continuation?.yield(
      matches.map {
        AutocompleteMatch(
          contents: $0.contents, description: $0.matchDescription, url: $0.destinationURL, type: $0.type,
          inlineAutocompletion: $0.inlineAutocompletion, keyword: $0.associatedKeyword,
          keywordName: $0.associatedKeywordName)
      })
    if done { continuation?.finish() }
  }
}
