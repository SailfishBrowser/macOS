import ComposableArchitecture
import Foundation

// A tab closed or archived from the sidebar, kept for the Library's Archived Tabs.
struct ArchivedTab: Codable, Equatable, Identifiable {
  let id: UUID
  let url: URL
  let title: String
  let profileID: UUID
  let archivedAt: Date
}

extension SharedKey where Self == InMemoryKey<IdentifiedArrayOf<ArchivedTab>>.Default {
  // Newest first.
  static var archive: Self { Self[.inMemory("archive"), default: []] }
}
