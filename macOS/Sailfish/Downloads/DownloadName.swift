import Foundation
import UniformTypeIdentifiers

// Tidy Downloads, on device: machine-made cruft (IDs, hashes, "(3)", camera counters, raw timestamps,
// URL escapes) comes out of a download's name, dates read as "Aug 17 2023", words are title-cased, and a name with
// nothing left says what it is and where it came from. A name without cruft is left alone.
enum DownloadName {
  // The tidier name for `name`, or nil when it is already well named. `title` is the file's own title, a PDF's.
  static func tidy(_ name: String, site: String?, title: String? = nil) -> String? {
    let ext = (name as NSString).pathExtension
    let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    var text = stem.removingPercentEncoding ?? stem
    var isMessy = text != stem || text.contains("_")
    func strip(_ pattern: some RegexComponent, with replacement: String = " ") {
      let stripped = text.replacing(pattern, with: { _ in replacement })
      if stripped != text { isMessy = true }
      text = stripped
    }
    strip(#/\s*(\((\d+|copy)\)|[ _-]copy)\s*$/#.ignoresCase(), with: "")
    strip(#/[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/#.ignoresCase())
    // A date, as 2023-08-17, 20230817 or 2023.08.17, with any time after it, which is dropped.
    text = text.replacing(
      #/(^|\D)(\d{4})[-_.]?(\d{2})[-_.]?(\d{2})(?!\d)(?:(?:T|[ _-](?:at[ _])?)\d{2}[-_.:]?\d{2}(?:[-_.:]?\d{2})?(?:\.\d+)?(?:Z|[ _]?[AP]M)?)?/#
    ) { match in
      guard let date = date(match.2, match.3, match.4) else { return String(match.0) }
      isMessy = true
      return "\(match.1) \(date) "
    }
    // A camera's prefix and counter, as in IMG_4821, say only what the file is.
    strip(#/^(?:img|pxl|dsc[nf]?|mvimg)(?:[_-]?\d{3,})?(?![a-z\d])/#.ignoresCase(), with: " Image ")
    strip(#/^(?:vid|gopr)(?:[_-]?\d{3,})?(?![a-z\d])/#.ignoresCase(), with: " Video ")
    var words = text.split(whereSeparator: { " _-+".contains($0) }).map(String.init)
    let kept = words.filter { !isCruft($0) }
    if kept.count != words.count { isMessy = true }
    words = kept
    // Where it came from: "Image from httpbin".
    var source = ""
    if words.allSatisfy({ generic.contains($0.lowercased()) }) {
      if let title, let titled = cleanTitle(title) {
        words = titled
      } else {
        words = [words.first ?? kind(of: ext)]
        source = site.flatMap(siteName).map { " from \($0)" } ?? ""
      }
      isMessy = true
    }
    guard isMessy, !words.isEmpty else { return nil }
    let tidied =
      words.enumerated().map { $0 > 0 && smallWords.contains($1) ? $1 : titleCased($1) }.joined(separator: " ") + source
    let named = ext.isEmpty ? tidied : "\(tidied).\(ext)"
    return named == name ? nil : named
  }

  // `name`, or "name 2.ext", "name 3.ext"… for the first that isn't taken, as the Finder numbers copies.
  static func unique(_ name: String, isTaken: (String) -> Bool) -> String {
    guard isTaken(name) else { return name }
    let ext = (name as NSString).pathExtension
    let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
    return (2...).lazy.map { ext.isEmpty ? "\(stem) \($0)" : "\(stem) \($0).\(ext)" }.first { !isTaken($0) }!
  }

  private static func date(_ year: Substring, _ month: Substring, _ day: Substring) -> String? {
    guard let year = Int(year), let month = Int(month), let day = Int(day), (1990...2099).contains(year),
      (1...12).contains(month), (1...31).contains(day)
    else { return nil }
    return "\(months[month - 1]) \(day) \(year)"
  }

  private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

  // IDs and hashes: six or more digits, hex runs with a digit, and long random mixes of cases and digits.
  private static func isCruft(_ word: String) -> Bool {
    let hasDigit = word.contains(where: \.isNumber)
    return word.wholeMatch(of: #/\d{6,}/#) != nil
      || (hasDigit && word.count >= 8 && word.wholeMatch(of: #/[0-9a-fA-F]+/#) != nil)
      || (hasDigit && word.count >= 10 && word.contains(where: \.isUppercase) && word.contains(where: \.isLowercase))
  }

  private static let generic: Set = [
    "download", "downloads", "file", "image", "img", "photo", "picture", "pic", "video", "untitled", "document",
    "attachment", "blob", "unknown", "media", "output",
  ]
  private static let smallWords: Set = ["a", "an", "and", "at", "by", "for", "from", "in", "of", "on", "or", "the", "to", "via"]

  // Words in lower case get a capital; any with capitals already, such as "PDF" or "iPhone", stay as they are.
  private static func titleCased(_ word: String) -> String {
    word == word.lowercased() ? word.prefix(1).uppercased() + word.dropFirst() : word
  }

  private static func cleanTitle(_ title: String) -> [String]? {
    let words = title.split(whereSeparator: { " _".contains($0) }).map(String.init).filter { !isCruft($0) }.prefix(8)
    return words.allSatisfy({ generic.contains($0.lowercased()) }) ? nil : Array(words)
  }

  private static func kind(of ext: String) -> String {
    guard let type = UTType(filenameExtension: ext) else { return "File" }
    if type.conforms(to: .image) { return "Image" }
    if type.conforms(to: .movie) { return "Video" }
    if type.conforms(to: .audio) { return "Audio" }
    if type.conforms(to: .pdf) { return "Document" }
    if type.conforms(to: .archive) { return "Archive" }
    return "File"
  }

  // The site's name from its host: "httpbin" for httpbin.org, "bbc" for www.bbc.co.uk.
  private static func siteName(_ host: String) -> String? {
    let labels = host.split(separator: ".").map(String.init)
    guard labels.count >= 2 else { return labels.first }
    let second = labels[labels.count - 2]
    return ["co", "com", "org", "net", "gov", "ac", "edu"].contains(second) && labels.count >= 3
      ? labels[labels.count - 3] : second
  }
}
