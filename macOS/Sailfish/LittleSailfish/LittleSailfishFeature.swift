import ComposableArchitecture
import Foundation

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // The first-use hint under the Open in button, shown until it is dismissed or a Little Sailfish with a page closes.
  static var littleSailfishHintShown: Self { Self[.appStorage("littleSailfishHintShown"), default: false] }
}

extension SharedKey where Self == FileStorageKey<[String: UUID]>.Default {
  // The profile last chosen in a Little Sailfish for each domain, which a Little Sailfish of that domain opens in again.
  static var littleSailfishProfiles: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "LittleSailfishProfiles.json")), default: [:]]
  }
}

// Little Sailfish: a small window for one page, opened for links from other apps or with ⌥⌘N, which
// shows only the command bar until a page is chosen.
@Reducer
struct LittleSailfishFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let id: UUID
    var profileID: UUID
    var tab: Tab?
    // Where a reopened Little Sailfish's window goes: the frame it closed with.
    let frame: CGRect?
    @Presents var commandBar: CommandBarFeature.State?
    // The Open In menu (⇧⌘O): the spaces the page can move to, with a search.
    var isOpenInMenuShown = false
    @Shared(.profiles) var profiles
    @Shared(.littleSailfishProfiles) var domainProfiles
    @Shared(.littleSailfishHintShown) var isHintShown

    // Without a page, the command bar shows, listing `recents` as recent pages.
    init(id: UUID, profileID: UUID, tab: Tab? = nil, recents: [Tab] = [], frame: CGRect? = nil) {
      self.id = id
      self.profileID = profileID
      self.tab = tab
      self.frame = frame
      if tab == nil {
        commandBar = CommandBarFeature.State(tabs: recents, profile: profileID, showsTabsAsRecents: true)
      }
    }
  }

  enum Action {
    case commandBar(PresentationAction<CommandBarFeature.Action>)
    case delegate(Delegate)
    case dismissHint
    case editURL
    case open(URL)
    case pageUpdated(WebPage)
    case setOpenInMenu(Bool)
    // The chip's menu: the page moves to the profile, which the domain opens in from then on.
    case switchProfile(Profile.ID)

    @CasePathable
    enum Delegate {
      case close
    }
  }

  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid
  @Dependency(\.webEngine) var engine

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .commandBar(.presented(.delegate(.open(url)))), let .commandBar(.presented(.delegate(.openInLittleSailfish(url)))):
        return .send(.open(url))

      // A recent page opens here rather than switching to its tab.
      case let .commandBar(.presented(.delegate(.selectTab(id)))):
        guard let tab = state.commandBar?.tabs.first(where: { $0.id == id }) else { return .none }
        return .send(.open(tab.url))

      // Closing the command bar of a Little Sailfish with no page closes it.
      case .commandBar(.dismiss):
        return state.tab == nil ? .send(.delegate(.close)) : .none

      case .commandBar, .delegate:
        return .none

      case .dismissHint:
        state.$isHintShown.withLock { $0 = true }
        return .none

      case .editURL:
        guard let tab = state.tab else { return .none }
        state.isOpenInMenuShown = false
        state.commandBar = CommandBarFeature.State(tabs: [], profile: state.profileID, query: tab.url.absoluteString)
        return .none

      case let .open(url):
        let url = url.chromePage
        state.commandBar = nil
        if let tab = state.tab {
          state.tab?.url = url
          return .run { _ in await engine.load(tab.id, url) }
        }
        if let remembered = state.domainProfiles[url.domain], state.profiles[id: remembered] != nil {
          state.profileID = remembered
        }
        return load(url, &state)

      case let .pageUpdated(page):
        state.tab?.update(page)
        return .none

      case let .setOpenInMenu(shown):
        state.isOpenInMenuShown = shown && state.tab != nil
        return .none

      case let .switchProfile(profile):
        guard profile != state.profileID, state.profiles[id: profile] != nil else { return .none }
        state.profileID = profile
        guard let tab = state.tab else { return .none }
        state.$domainProfiles.withLock { $0[tab.url.domain] = profile }
        return .merge(.run { _ in await engine.close(tab.id) }, load(tab.url, &state))
      }
    }
    .ifLet(\.$commandBar, action: \.commandBar) {
      CommandBarFeature()
    }
  }

  // A fresh page of the profile showing the URL.
  private func load(_ url: URL, _ state: inout State) -> Effect<Action> {
    let tab = Tab(
      id: uuid(), url: url, title: url.host() ?? url.absoluteString, placement: .unpinned, createdAt: now,
      lastActiveAt: now, isLive: true)
    state.tab = tab
    return .run { [id = state.id, profile = state.profileID] _ in
      await engine.create(tab.id, profile, false)
      await engine.littleWindow(id, profile, tab.id)
      await engine.load(tab.id, url)
    }
  }
}
