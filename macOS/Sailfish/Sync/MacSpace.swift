import Foundation

// A space as the phone reads it from iCloud; the iOS app declares the same type.
struct MacSpace: Codable, Equatable, Sendable {
  struct Page: Codable, Equatable, Sendable {
    let url: URL
    let title: String
    // A 32-pixel PNG of the page's favicon.
    let icon: Data?
  }
  let name: String
  let pinned: [Page]
  let tabs: [Page]
}
