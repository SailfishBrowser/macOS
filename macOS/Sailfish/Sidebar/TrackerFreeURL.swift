import AppKit

extension URL {
  // The URL without the query parameters that trackers add, left out when a link is copied.
  var withoutTrackers: URL {
    // The raw items, so a kept value's escapes, such as "%2B", stay as they were.
    guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
      let items = components.percentEncodedQueryItems
    else { return self }
    let kept = items.filter { !Self.isTracker($0.name) }
    guard kept.count != items.count else { return self }
    components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
    return components.url!
  }

  private static func isTracker(_ name: String) -> Bool {
    let name = name.lowercased()
    return name.hasPrefix("utm_") || trackers.contains(name)
  }

  private static let trackers: Set<String> = [
    "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "igshid",
    "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "li_fat_id", "oly_anon_id", "oly_enc_id", "vero_id",
  ]
}

// Copy URL: the page's link without trackers.
@MainActor
func copyLink(_ url: URL) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(url.withoutTrackers.absoluteString, forType: .string)
}
