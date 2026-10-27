import ComposableArchitecture
import Foundation
import UniformTypeIdentifiers

@Reducer
struct LibraryFeature {
  // The raw values are the menu items' tags, which saved shortcuts key on.
  enum Pane: Int {
    case downloads = 0
    case spaces = 1
    case archive = 3
    case media = 4
  }

  @ObservableState
  struct State: Equatable {
    var pane: Pane
    var query = ""
    // Downloads are filtered by the profile they were made in.
    var profile: Profile.ID?
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case select(Pane)
  }

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none
      case let .select(pane):
        state.pane = pane
        state.query = ""
        state.profile = nil
        return .none
      }
    }
  }

  // The downloads matching the query and profile, grouped under headings ("Today", "6 days ago",
  // "1 week ago"), newest first.
  static func groups(
    _ downloads: [Download], query: String, profile: Profile.ID?, now: Date, calendar: Calendar
  ) -> [(title: String, downloads: [Download])] {
    groups(
      downloads.filter {
        (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) && (profile == nil || $0.profileID == profile)
      },
      date: \.startTime, now: now, calendar: calendar
    ).map { ($0.title, $0.items) }
  }

  // Archived tabs matching the query by title or URL, grouped by day as downloads are.
  static func groups(
    _ archive: [ArchivedTab], query: String, profile: Profile.ID?, now: Date, calendar: Calendar
  ) -> [(title: String, items: [ArchivedTab])] {
    groups(
      archive.filter {
        (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
          || $0.url.absoluteString.localizedCaseInsensitiveContains(query))
          && (profile == nil || $0.profileID == profile)
      },
      date: \.archivedAt, now: now, calendar: calendar)
  }

  // Media: the downloaded images and videos matching the query, newest first.
  static func media(_ downloads: [Download], query: String) -> [Download] {
    downloads.filter {
      $0.state == .complete && ($0.type.conforms(to: .image) || $0.type.conforms(to: .movie))
        && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
    }
  }

  private static func groups<T>(
    _ items: [T], date: (T) -> Date, now: Date, calendar: Calendar
  ) -> [(title: String, items: [T])] {
    var groups: [(title: String, items: [T])] = []
    let formatter = RelativeDateTimeFormatter()
    formatter.calendar = calendar
    for item in items {
      let title = groupTitle(date(item), now: now, calendar: calendar, formatter: formatter)
      if groups.last?.title == title {
        groups[groups.count - 1].items.append(item)
      } else {
        groups.append((title, [item]))
      }
    }
    return groups
  }

  static func groupTitle(_ date: Date, now: Date, calendar: Calendar, formatter: RelativeDateTimeFormatter) -> String {
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
    ).day!
    switch days {
    case ..<1: return "Today"
    case ..<7: return formatter.localizedString(from: DateComponents(day: -days))
    case ..<30: return formatter.localizedString(from: DateComponents(weekOfMonth: -days / 7))
    case ..<365: return formatter.localizedString(from: DateComponents(month: -days / 30))
    default: return formatter.localizedString(from: DateComponents(year: -days / 365))
    }
  }
}

extension Download {
  var name: String { fileURL?.lastPathComponent ?? url.lastPathComponent }

  var type: UTType { UTType(filenameExtension: (name as NSString).pathExtension) ?? .data }
}

// The places Media shows images and videos from, picked in the Library button's "Show media from:" menu.
struct MediaSources: OptionSet, CaseIterable, Sendable {
  let rawValue: Int
  static let documents = Self(rawValue: 1 << 0)
  static let desktop = Self(rawValue: 1 << 1)
  static let captures = Self(rawValue: 1 << 2)
  static let downloads = Self(rawValue: 1 << 3)
  static let screenshots = Self(rawValue: 1 << 4)
  // In the menu's order.
  static let allCases: [Self] = [.documents, .desktop, .screenshots, .captures, .downloads]

  // The screenshots folder is named as Finder names it, so it may read Desktop or Documents twice.
  var title: String {
    switch self {
    case .documents: "Documents"
    case .desktop: "Desktop"
    case .screenshots: FileManager.default.displayName(atPath: Self.screenshotsFolder.path)
    case .captures: "Sailfish Captures"
    default: "Downloads"
    }
  }

  var folder: URL? {
    switch self {
    case .documents: .documentsDirectory
    case .desktop: .desktopDirectory
    case .screenshots: Self.screenshotsFolder
    case .downloads: .downloadsDirectory
    default: nil
    }
  }

  // Where macOS saves screenshots: the Screenshot app's "Save to", or the Desktop until one is picked.
  static var screenshotsFolder: URL {
    UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location").map {
      URL(filePath: NSString(string: $0).expandingTildeInPath, directoryHint: .isDirectory)
    } ?? .desktopDirectory
  }
}

extension SharedKey where Self == AppStorageKey<MediaSources>.Default {
  // A new key, so that installs which saved the four earlier sources get the screenshots folder too.
  static var mediaSources: Self { Self[.appStorage("mediaSourcesWithScreenshots"), default: MediaSources(MediaSources.allCases)] }
}

extension SharedKey where Self == AppStorageKey<Date?> {
  // When the person started using Sailfish; Media leaves out folder files from before it.
  static var firstLaunch: Self { .appStorage("firstLaunch") }
}

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  // Whether the media folders' macOS access prompts were raised, at onboarding or at launch; Media reads them only
  // after, so that opening the Library never prompts.
  static var mediaFoldersAsked: Self { Self[.appStorage("mediaFoldersAsked"), default: false] }
}

private enum RequestMediaFoldersKey: DependencyKey {
  // Touches each media folder in the menu's order, so that macOS asks for each protected one in turn; each
  // touch waits until its prompt is answered. A folder already allowed or denied is not asked again.
  static let liveValue: @Sendable () async -> Void = {
    let folders = MediaSources.allCases.compactMap(\.folder).map(\.standardizedFileURL)
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        for (index, folder) in folders.enumerated() where !folders[..<index].contains(folder) {
          _ = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        }
        continuation.resume()
      }
    }
  }
  static let testValue: @Sendable () async -> Void = {}
}

extension DependencyValues {
  var requestMediaFolders: @Sendable () async -> Void {
    get { self[RequestMediaFoldersKey.self] }
    set { self[RequestMediaFoldersKey.self] = newValue }
  }
}

extension SharedKey where Self == FileStorageKey<Set<URL>>.Default {
  // The files Media's Hide from Sailfish took out of it.
  static var hiddenMedia: Self { Self[.fileStorage(URL.dataDirectory.appending(path: "HiddenMedia.json")), default: []] }
}

extension LibraryFeature {
  // The images and videos directly in the folders created since the date, with when each was last changed.
  // A folder picked twice, such as Documents as the screenshots folder, is read once.
  static func mediaFiles(in folders: [URL], since: Date) -> [(url: URL, date: Date)] {
    Set(folders.map(\.standardizedFileURL.path)).flatMap { path in
      let folder = URL(filePath: path, directoryHint: .isDirectory)
      let files = (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.contentTypeKey, .creationDateKey, .contentModificationDateKey],
        options: .skipsHiddenFiles)) ?? []
      return files.compactMap { file -> (url: URL, date: Date)? in
        guard
          let values = try? file.resourceValues(forKeys: [.contentTypeKey, .creationDateKey, .contentModificationDateKey]),
          let type = values.contentType, type.conforms(to: .image) || type.conforms(to: .movie),
          let created = values.creationDate, created >= since
        else { return nil }
        return (file, values.contentModificationDate ?? .distantPast)
      }
    }
  }

  // The folders' media, then again whenever a file is added to, removed from or renamed in one of them. Reading and
  // watching run on their own queue. A folder whose access was denied reads as empty.
  static func media(in folders: [URL], since: Date) -> AsyncStream<[(url: URL, date: Date)]> {
    AsyncStream { continuation in
      let queue = DispatchQueue(label: "Library media folders")
      let watch = FolderWatch()
      queue.async {
        continuation.yield(mediaFiles(in: folders, since: since))
        watch.sources = folders.compactMap { folder in
          let descriptor = open(folder.path, O_EVTONLY)
          guard descriptor >= 0 else { return nil }
          let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
          source.setEventHandler { continuation.yield(mediaFiles(in: folders, since: since)) }
          source.setCancelHandler { close(descriptor) }
          source.resume()
          return source
        }
      }
      continuation.onTermination = { _ in queue.async { watch.sources.forEach { $0.cancel() } } }
    }
  }
}

// The watched folders' sources, touched only on their queue.
private final class FolderWatch: @unchecked Sendable {
  var sources: [DispatchSourceFileSystemObject] = []
}
