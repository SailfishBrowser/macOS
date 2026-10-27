import ComposableArchitecture
import Foundation

// Space Linking: routes that send links from other apps to a chosen place, the first match winning,
// and where the rest go.
struct LinkRoutes: Codable, Equatable {
  enum Destination: Codable, Hashable {
    case space(Space.ID)
    case mostRecentSpace
    case littleSailfish
  }

  enum Match: String, Codable, CaseIterable {
    case isEqualTo = "Is equal to"
    case contains = "Contains"
  }

  struct Route: Codable, Equatable, Identifiable {
    let id: UUID
    var match = Match.contains
    var text = ""
    var destination = Destination.mostRecentSpace

    func matches(_ url: URL) -> Bool {
      let text = text.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { return false }
      switch match {
      case .isEqualTo: return url.absoluteString.caseInsensitiveCompare(text) == .orderedSame
      case .contains: return url.absoluteString.localizedCaseInsensitiveContains(text)
      }
    }
  }

  var routes: [Route]
  var defaultDestination: Destination

  // One route ships by default: Meet links open in the current space.
  static let initial = LinkRoutes(
    routes: [Route(id: UUID(uuidString: "6D2E1F4C-2B0A-4B8E-9C61-1E0B8F0A7A10")!, text: "meet.google.com")],
    defaultDestination: .littleSailfish)

  // The first route that matches, else the default; a route or default to a space that is gone is passed over.
  func destination(for url: URL, spaces: Set<Space.ID>) -> Destination {
    let exists = { (destination: Destination) in
      if case let .space(id) = destination { return spaces.contains(id) }
      return true
    }
    let route = routes.first { $0.matches(url) && exists($0.destination) }
    return route?.destination ?? (exists(defaultDestination) ? defaultDestination : .mostRecentSpace)
  }
}

extension SharedKey where Self == FileStorageKey<LinkRoutes>.Default {
  static var linkRoutes: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "LinkRoutes.json")), default: .initial]
  }
}
