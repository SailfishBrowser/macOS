import Foundation

// The browsers an import can read.
enum SourceBrowser: String, CaseIterable, Equatable, Sendable {
  case arc = "Arc"
  case dia = "Dia"
  case chrome = "Google Chrome"
  case safari = "Safari"
  case edge = "Microsoft Edge"
  case zen = "Zen"

  var bundleID: String {
    switch self {
    case .arc: "company.thebrowser.Browser"
    case .dia: "company.thebrowser.dia"
    case .chrome: "com.google.Chrome"
    case .safari: "com.apple.Safari"
    case .edge: "com.microsoft.edgemac"
    case .zen: "app.zen-browser.zen"
    }
  }

  // The Chromium user data directory under Application Support; nil for Safari and Zen.
  var userData: String? {
    switch self {
    case .arc: "Arc/User Data"
    case .dia: "Dia/User Data"
    case .chrome: "Google/Chrome"
    case .edge: "Microsoft Edge"
    case .safari, .zen: nil
    }
  }

  // The keychain item whose password Chromium derives its key for passwords and cookies from; nil for Safari and Zen.
  var safeStorage: String? {
    switch self {
    case .arc: "Arc Safe Storage"
    case .dia: "Dia Safe Storage"
    case .chrome: "Chrome Safe Storage"
    case .edge: "Microsoft Edge Safe Storage"
    case .safari, .zen: nil
    }
  }

  // Chromium keeps it in Network since version 96, in the profile before.
  func cookiesFile(_ profile: BrowserProfile) -> URL {
    if self == .safari {
      return profile.folder.deletingLastPathComponent()
        .appending(path: "Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
    }
    let network = profile.folder.appending(path: "Network/Cookies")
    return FileManager.default.fileExists(atPath: network.path) ? network : profile.folder.appending(path: "Cookies")
  }

  func bookmarksFile(_ profile: BrowserProfile) -> URL {
    profile.folder.appending(path: self == .safari ? "Bookmarks.plist" : "Bookmarks")
  }

  func historySource(_ profile: BrowserProfile) -> HistorySource {
    HistorySource(
      browser: rawValue, profile: profile.name,
      file: profile.folder.appending(path: self == .safari ? "History.db" : self == .zen ? "places.sqlite" : "History"))
  }
}

// A Chromium or Zen profile's folder, or Safari's, which has one.
struct BrowserProfile: Equatable, Hashable, Identifiable, Sendable {
  var name: String
  var folder: URL

  var id: URL { folder }
  var isDefault: Bool { folder.lastPathComponent == "Default" }
}

// An installed browser that has data to import. Arc's profiles are read from the folder its import picks.
struct BrowserSource: Equatable, Identifiable, Sendable {
  var browser: SourceBrowser
  var profiles: [BrowserProfile]

  var id: SourceBrowser { browser }
}

enum BrowserSources {
  static func detect(home: URL) -> [BrowserSource] {
    let support = home.appending(path: "Library/Application Support")
    let exists = { (file: URL) in FileManager.default.fileExists(atPath: file.path) }
    return SourceBrowser.allCases.compactMap { browser in
      switch browser {
      case .arc:
        return exists(ArcReader.defaultFolder(home: home).appending(path: "StorableSidebar.json"))
          ? BrowserSource(browser: browser, profiles: []) : nil
      case .safari:
        // Without Full Disk Access the files can be seen but not read; the import says so.
        let safari = BrowserProfile(name: "", folder: home.appending(path: "Library/Safari"))
        let has = exists(browser.bookmarksFile(safari)) || exists(browser.historySource(safari).file)
        return has ? BrowserSource(browser: browser, profiles: [safari]) : nil
      case .zen:
        let profiles = zenProfiles(support.appending(path: "zen"))
        return profiles.isEmpty ? nil : BrowserSource(browser: browser, profiles: profiles)
      case .dia, .chrome, .edge:
        let profiles = chromiumProfiles(support.appending(path: browser.userData!), browser)
        return profiles.isEmpty ? nil : BrowserSource(browser: browser, profiles: profiles)
      }
    }
  }

  private struct LocalState: Decodable {
    struct Profiles: Decodable { let info_cache: [String: Info] }
    struct Info: Decodable { let name: String }
    let profile: Profiles
  }

  // The profiles Local State lists that have bookmarks or history, in Chrome's order of their folders.
  static func chromiumProfiles(_ userData: URL, _ browser: SourceBrowser) -> [BrowserProfile] {
    let state = (try? Data(contentsOf: userData.appending(path: "Local State")))
      .flatMap { try? JSONDecoder().decode(LocalState.self, from: $0) }
    return (state?.profile.info_cache ?? [:])
      .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
      .map { BrowserProfile(name: $0.value.name, folder: userData.appending(path: $0.key)) }
      .filter {
        FileManager.default.fileExists(atPath: browser.bookmarksFile($0).path)
          || FileManager.default.fileExists(atPath: browser.historySource($0).file.path)
      }
  }

  // Zen's profiles that have history, the one its install opens first: installs.ini names it, else profiles.ini.
  static func zenProfiles(_ root: URL) -> [BrowserProfile] {
    let profiles = ini(root.appending(path: "profiles.ini"))
    var listed = profiles.filter { $0.name.hasPrefix("Profile") }.compactMap { section -> (path: String, profile: BrowserProfile)? in
      guard let name = section.keys["Name"], let path = section.keys["Path"] else { return nil }
      let folder = section.keys["IsRelative"] == "0" ? URL(filePath: path) : root.appending(path: path)
      return (path, BrowserProfile(name: name, folder: folder))
    }
    .filter { FileManager.default.fileExists(atPath: $0.profile.folder.appending(path: "places.sqlite").path) }
    let defaults = (ini(root.appending(path: "installs.ini")) + profiles.filter { $0.name.hasPrefix("Install") })
      .compactMap { $0.keys["Default"] } + profiles.filter { $0.keys["Default"] == "1" }.compactMap { $0.keys["Path"] }
    if let index = defaults.lazy.compactMap({ path in listed.firstIndex { $0.path == path } }).first {
      listed.insert(listed.remove(at: index), at: 0)
    }
    return listed.map(\.profile)
  }

  // An INI file's sections in order, each with its keys.
  private static func ini(_ file: URL) -> [(name: String, keys: [String: String])] {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    var sections: [(name: String, keys: [String: String])] = []
    for line in text.split(whereSeparator: \.isNewline) {
      if line.hasPrefix("["), line.hasSuffix("]") {
        sections.append((String(line.dropFirst().dropLast()), [:]))
      } else if let equals = line.firstIndex(of: "="), !sections.isEmpty {
        sections[sections.count - 1].keys[String(line[..<equals])] = String(line[line.index(after: equals)...])
      }
    }
    return sections
  }
}
