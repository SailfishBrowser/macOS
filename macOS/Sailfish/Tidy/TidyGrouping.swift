import Foundation
import NaturalLanguage

struct TidyTab: Equatable, Sendable {
  let id: Tab.ID
  let title: String
  let host: String
}

struct TidyGroup: Equatable, Sendable {
  let name: String
  let tabIDs: [Tab.ID]
}

// Tidy's grouping, all on the Mac: tabs of one site, then the rest that share a word in their titles, two or more a
// group, in the order of each group's first tab.
func sortIntoGroups(_ tabs: [TidyTab]) -> [TidyGroup] {
  let bySite = Dictionary(grouping: tabs.filter { !site($0.host).isEmpty }) { site($0.host) }
  var groups = bySite.values.filter { $0.count > 1 }.map { TidyGroup(name: siteName($0), tabIDs: $0.map(\.id)) }
  var left = tabs.filter { bySite[site($0.host)]?.count ?? 1 == 1 }
  var words = left.map(keywords)
  while true {
    let order = words.flatMap { $0.map(\.key) }
    let counts = order.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
    let most = counts.values.max() ?? 0
    guard most > 1, let key = order.first(where: { counts[$0] == most }) else { break }
    let picked = left.indices.filter { words[$0].contains { $0.key == key } }
    groups.append(TidyGroup(name: words[picked[0]].first { $0.key == key }!.word, tabIDs: picked.map { left[$0].id }))
    for index in picked.reversed() {
      left.remove(at: index)
      words.remove(at: index)
    }
  }
  let position = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })
  return groups.sorted { position[$0.tabIDs[0]]! < position[$1.tabIDs[0]]! }
}

// A site is its host without www. or m., so Gmail and Google Docs stay apart.
private func site(_ host: String) -> String {
  let host = host.lowercased()
  for prefix in ["www.", "m."] where host.hasPrefix(prefix) {
    return String(host.dropFirst(prefix.count))
  }
  return host
}

private let separators = [" - ", " | ", " · ", " — ", " – ", " • "]

private func segments(_ title: String) -> [String] {
  separators.reduce([title]) { parts, separator in parts.flatMap { $0.components(separatedBy: separator) } }
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
}

// The name the site gives itself in its titles ("… · GitHub", "YouTube - …"), else the host's ("bbc.co.uk" is "BBC"
// if a title spells it so).
private func siteName(_ tabs: [TidyTab]) -> String {
  let candidates = tabs.map { tab in
    let parts = segments(tab.title)
    return parts.count > 1 ? [parts.last!, parts.first!] : parts
  }
  let order = candidates.joined().filter { $0.count <= 30 }
  let counts = order.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
  let most = counts.values.max() ?? 0
  if most > 1, let name = order.first(where: { counts[$0] == most }) {
    return name
  }
  var labels = site(tabs[0].host).split(separator: ".").dropLast()
  if labels.count > 1, ["co", "com", "org", "net", "gov", "edu", "ac"].contains(labels.last!) {
    labels = labels.dropLast()
  }
  guard let label = labels.last else { return tabs[0].host }
  return tabs.flatMap { segments($0.title) }.first { $0.lowercased() == label } ?? capitalized(String(label))
}

// Words too common in titles to make a topic.
private let commonWords: Set<String> = [
  "about", "account", "and", "app", "are", "best", "but", "can", "dashboard", "docs", "documentation", "for", "free",
  "from", "get", "good", "guide", "has", "have", "home", "how", "inbox", "into", "login", "more", "new", "news", "not",
  "official", "online", "our", "out", "page", "review", "search", "settings", "sign", "site", "that", "the", "this",
  "top", "untitled", "video", "was", "welcome", "what", "when", "why", "will", "with", "you", "your",
]

// A tab's title words, each once by its lemma, with how the title spells it; without the site's own name.
private func keywords(_ tab: TidyTab) -> [(key: String, word: String)] {
  var parts = segments(tab.title)
  if parts.count > 1 { parts.removeLast() }
  let text = parts.joined(separator: " ")
  let tagger = NLTagger(tagSchemes: [.lemma])
  tagger.string = text
  var words: [(key: String, word: String)] = []
  tagger.enumerateTags(
    in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma, options: [.omitPunctuation, .omitWhitespace]
  ) { lemma, range in
    let word = String(text[range])
    let key = (lemma?.rawValue ?? word).lowercased()
    if key.count > 2, key.contains(where: \.isLetter), !commonWords.contains(key),
      !words.contains(where: { $0.key == key })
    {
      words.append((key, capitalized(word)))
    }
    return true
  }
  return words
}

// "chicken" is "Chicken"; "iPhone" stays.
private func capitalized(_ word: String) -> String {
  word == word.lowercased() ? word.prefix(1).uppercased() + word.dropFirst() : word
}
