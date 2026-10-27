import Foundation

// The browsers an import can read.
enum SourceBrowser: String, CaseIterable, Equatable, Sendable {
  case arc = "Arc"
  case dia = "Dia"
  case chrome = "Google Chrome"
  case safari = "Safari"
  case edge = "Microsoft Edge"

  var bundleID: String {
    switch self {
    case .arc: "company.thebrowser.Browser"
    case .dia: "company.thebrowser.dia"
    case .chrome: "com.google.Chrome"
    case .safari: "com.apple.Safari"
    case .edge: "com.microsoft.edgemac"
    }
  }

  // The Chromium user data directory under Application Support; nil for Safari.
  var userData: String? {
    switch self {
    case .arc: "Arc/User Data"
    case .dia: "Dia/User Data"
    case .chrome: "Google/Chrome"
    case .edge: "Microsoft Edge"
    case .safari: nil
    }
  }

  // The keychain item whose password Chromium derives its key for passwords and cookies from; nil for Safari.
  var safeStorage: String? {
    switch self {
    case .arc: "Arc Safe Storage"
    case .dia: "Dia Safe Storage"
    case .chrome: "Chrome Safe Storage"
    case .edge: "Microsoft Edge Safe Storage"
    case .safari: nil
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
      file: profile.folder.appending(path: self == .safari ? "History.db" : "History"))
  }
}

// A Chromium profile's folder, or Safari's, which has one.
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
}
