import ComposableArchitecture
import SwiftUI

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // Off, a favorite's or pinned tab's link to another site opens in the tab itself instead of Peek.
  static var peeksLinksToOtherSites: Self { Self[.appStorage("peeksLinksToOtherSites"), default: true] }
  // Off, a ⌥⌘-click opens the link as a ⌘-click does instead of in a Little Sailfish.
  static var littleSailfishOnOptionCommandClick: Self { Self[.appStorage("littleSailfishOnOptionCommandClick"), default: true] }
  // Off, a ⇧-click opens the link in a tab in front instead of in Peek.
  static var peeksOnShiftClick: Self { Self[.appStorage("peeksOnShiftClick"), default: true] }
}

struct LinksPane: View {
  let store: StoreOf<AppFeature>
  @Shared(.littleSailfishHotKey) private var littleSailfishHotKey
  @Shared(.linkRoutes) private var linkRoutes
  @Shared(.peeksLinksToOtherSites) private var peeksLinksToOtherSites
  @Shared(.littleSailfishOnOptionCommandClick) private var littleSailfishOnOptionCommandClick
  @Shared(.peeksOnShiftClick) private var peeksOnShiftClick
  @State private var isSpaceLinkingShown = false

  // The toggle is Space Linking's default: on is Little Sailfish, off the most recent space.
  private var linksOpenInLittleSailfish: Binding<Bool> {
    Binding(
      get: { linkRoutes.defaultDestination == .littleSailfish },
      set: { isOn in $linkRoutes.withLock { $0.defaultDestination = isOn ? .littleSailfish : .mostRecentSpace } }
    )
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        LittleSailfishBanner()
        VStack(spacing: 0) {
          SettingsToggle("Open Little Sailfish when I press ⌥⌘N in any app", isOn: $littleSailfishHotKey)
          Divider().padding(.horizontal, 10)
          SettingsToggle("Open Little Sailfish when clicking on links with ⌥⌘ held", isOn: $littleSailfishOnOptionCommandClick)
          Divider().padding(.horizontal, 10)
          SettingsRow("Links from other apps open in Little Sailfish") {
            Toggle("", isOn: linksOpenInLittleSailfish).toggleStyle(.switch).controlSize(.mini).labelsHidden()
          }
        }
        .settingsCard()
        .padding(.horizontal, 64)
        Divider().padding(.horizontal, 64)
        VStack(spacing: 0) {
          SettingsToggle("Open a Peek window when clicking on links with Shift held", isOn: $peeksOnShiftClick)
          Divider().padding(.horizontal, 10)
          SettingsToggle("Open links to other sites from Favorites and Pinned tabs in Peek", isOn: $peeksLinksToOtherSites)
        }
        .settingsCard()
        .padding(.horizontal, 64)
        Divider().padding(.horizontal, 64)
        SettingsRow("Space Linking") {
          Button("Edit…") { isSpaceLinkingShown = true }
        }
        .settingsCard()
        .padding(.horizontal, 64)
      }
      .padding(.bottom, 20)
    }
    .sheet(isPresented: $isSpaceLinkingShown) {
      SpaceLinking(spaces: spaceChoices) { isSpaceLinkingShown = false }
    }
  }

  // Every regular window's spaces, named with their profile.
  private var spaceChoices: [(Space.ID, String)] {
    store.windows.filter { !$0.isIncognito }.flatMap(\.spaces.spaces).map { space in
      (space.id, "\(space.name) (\(store.profiles[id: space.profileID]!.name))")
    }
  }
}

// A Little Sailfish window on a colored band with a wavy bottom edge.
private struct LittleSailfishBanner: View {
  var body: some View {
    ZStack(alignment: .bottom) {
      Color(hex: 0xD48585)
      VStack(spacing: 0) {
        HStack(spacing: 5) {
          ForEach(0..<3, id: \.self) { _ in Circle().fill(.black.opacity(0.15)).frame(width: 7, height: 7) }
          Spacer()
          Text("example.com").font(.system(size: 10)).foregroundStyle(.black.opacity(0.6))
          Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color(hex: 0xEDEDED))
        Color(hex: 0xC99C9C)
      }
      .clipShape(.rect(topLeadingRadius: 6, topTrailingRadius: 6))
      .frame(width: 560, height: 90)
    }
    .frame(height: 134)
    .clipShape(Wave())
  }
}

private struct Wave: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: .zero)
    path.addLine(to: CGPoint(x: rect.maxX, y: 0))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 4))
    for x in stride(from: rect.maxX, to: 0, by: -16) {
      path.addQuadCurve(to: CGPoint(x: x - 16, y: rect.maxY - 4), control: CGPoint(x: x - 8, y: rect.maxY + 4))
    }
    path.closeSubpath()
    return path
  }
}
