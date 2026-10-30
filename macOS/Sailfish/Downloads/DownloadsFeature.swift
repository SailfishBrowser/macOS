import ComposableArchitecture
import Foundation
import PDFKit

extension SharedKey where Self == FileStorageKey<Set<String>>.Default {
  // The keys of the downloads hidden from Sailfish, which never show again.
  static var hiddenDownloads: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "HiddenDownloads.json")), default: []]
  }
}

extension SharedKey where Self == FileStorageKey<[String: String]>.Default {
  // The new names of the downloads Tidy Downloads renamed, by key; the engine keeps the names they downloaded under.
  static var renamedDownloads: Self {
    Self[.fileStorage(URL.dataDirectory.appending(path: "RenamedDownloads.json")), default: [:]]
  }
}

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  static var tidyDownloads: Self { Self[.appStorage("tidyDownloads"), default: true] }
}

extension Download {
  // The engine's IDs follow the order profiles load in, so a hidden download is remembered by its URL and start.
  var hiddenKey: String { "\(startTime.timeIntervalSince1970) \(url.absoluteString)" }
}

@Reducer
struct DownloadsFeature {
  @ObservableState
  struct State: Equatable {
    // Newest first.
    var downloads: IdentifiedArrayOf<Download> = []
    // The download that just finished, whose icon shows on the Library button for half a minute.
    var finished: Download.ID?
    @Shared(.hiddenDownloads) var hidden
    @Shared(.renamedDownloads) var renamed
    @Shared(.tidyDownloads) var tidiesNames
  }

  enum Action {
    case cancel(Download.ID)
    // Hide: the file stays on disk and leaves every list.
    case hide(Download.ID)
    // Move to Trash, which takes the download off the lists too.
    case moveToTrash(Download.ID)
    case finishedShown(Download.ID)
    case updated(Download)
    // Tidy Downloads renamed the finished file to this.
    case renamed(Download.ID, URL)
    // The renamed toast's Undo: the file takes back the name it downloaded under.
    case revertName(Download.ID)
    case reverted(Download.ID)
  }

  @Dependency(\.webEngine) var engine
  @Dependency(\.soundEffects) var sounds
  @Dependency(\.trashFile) var trashFile
  @Dependency(\.tidyDownload) var tidyDownload
  @Dependency(\.moveFile) var moveFile
  @Dependency(\.continuousClock) var clock
  private enum CancelID { case finished }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .cancel(id):
        return .run { _ in await engine.cancelDownload(id) }

      case let .hide(id):
        guard let download = state.downloads.remove(id: id) else { return .none }
        _ = state.$hidden.withLock { $0.insert(download.hiddenKey) }
        state.$renamed.withLock { $0[download.hiddenKey] = nil }
        return .none

      case let .finishedShown(id):
        if state.finished == id { state.finished = nil }
        return .none

      case let .moveToTrash(id):
        guard let file = state.downloads[id: id]?.fileURL else { return .none }
        return .run { send in
          try await trashFile(file)
          await send(.hide(id))
        }

      case var .updated(download):
        guard !state.hidden.contains(download.hiddenKey) else { return .none }
        if let name = state.renamed[download.hiddenKey], let file = download.fileURL {
          download.originalName = file.lastPathComponent
          download.fileURL = file.deletingLastPathComponent().appending(path: name)
        }
        if state.downloads[id: download.id] == nil {
          let index = state.downloads.firstIndex { $0.startTime < download.startTime } ?? state.downloads.count
          state.downloads.insert(download, at: index)
        } else {
          let finished = state.downloads[id: download.id]?.state == .inProgress && download.state == .complete
          state.downloads[id: download.id] = download
          guard finished else { return .none }
          state.finished = download.id
          // A chime, once the file is on disk; its icon leaves the Library button 30 s later.
          let shown = Effect<Action>.run { [download] send in
            await sounds.play(.downloadComplete)
            try await clock.sleep(for: .seconds(30))
            await send(.finishedShown(download.id))
          }
          .cancellable(id: CancelID.finished, cancelInFlight: true)
          // An extension's .crx is the engine's to install from the path it downloaded to (the Chrome Web Store's
          // installs too): renamed, the install finds no file and only the download is left.
          guard state.tidiesNames, download.originalName == nil, let file = download.fileURL,
            file.pathExtension.lowercased() != "crx"
          else { return shown }
          return .merge(shown, .run { [download] send in
            if let renamed = try await tidyDownload(file, download.url.host()) {
              await send(.renamed(download.id, renamed))
            }
          })
        }
        return .none

      case let .renamed(id, file):
        guard let download = state.downloads[id: id], let old = download.fileURL else { return .none }
        _ = state.$renamed.withLock { $0[download.hiddenKey] = file.lastPathComponent }
        state.downloads[id: id]?.originalName = old.lastPathComponent
        state.downloads[id: id]?.fileURL = file
        return .none

      case let .revertName(id):
        guard let file = state.downloads[id: id]?.fileURL, let original = state.downloads[id: id]?.originalName
        else { return .none }
        return .run { send in
          try await moveFile(file, file.deletingLastPathComponent().appending(path: original))
          await send(.reverted(id))
        }

      case let .reverted(id):
        guard let download = state.downloads[id: id], let file = download.fileURL, let original = download.originalName
        else { return .none }
        _ = state.$renamed.withLock { $0.removeValue(forKey: download.hiddenKey) }
        state.downloads[id: id]?.fileURL = file.deletingLastPathComponent().appending(path: original)
        state.downloads[id: id]?.originalName = nil
        return .none
      }
    }
  }
}

private enum TrashFileKey: DependencyKey {
  static let liveValue: @Sendable (URL) async throws -> Void = {
    try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
  }
  static let testValue: @Sendable (URL) async throws -> Void = unimplemented("trashFile")
}

extension DependencyValues {
  var trashFile: @Sendable (URL) async throws -> Void {
    get { self[TrashFileKey.self] }
    set { self[TrashFileKey.self] = newValue }
  }
}

private enum TidyDownloadKey: DependencyKey {
  // Renames the finished file to its tidier name, if it has one, and returns where it went.
  static let liveValue: @Sendable (URL, String?) async throws -> URL? = { file, site in
    let title =
      file.pathExtension.lowercased() == "pdf"
      ? PDFDocument(url: file)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String : nil
    guard let name = DownloadName.tidy(file.lastPathComponent, site: site, title: title) else { return nil }
    let folder = file.deletingLastPathComponent()
    let renamed = folder.appending(path: DownloadName.unique(name) {
      FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
    })
    try FileManager.default.moveItem(at: file, to: renamed)
    return renamed
  }
  static let testValue: @Sendable (URL, String?) async throws -> URL? = unimplemented("tidyDownload")
}

private enum MoveFileKey: DependencyKey {
  static let liveValue: @Sendable (URL, URL) async throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
  static let testValue: @Sendable (URL, URL) async throws -> Void = unimplemented("moveFile")
}

extension DependencyValues {
  var tidyDownload: @Sendable (URL, String?) async throws -> URL? {
    get { self[TidyDownloadKey.self] }
    set { self[TidyDownloadKey.self] = newValue }
  }

  var moveFile: @Sendable (URL, URL) async throws -> Void {
    get { self[MoveFileKey.self] }
    set { self[MoveFileKey.self] = newValue }
  }
}
