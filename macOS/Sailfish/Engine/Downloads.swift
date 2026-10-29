@preconcurrency import EngineCore

// A download's ID is its context's index in downloadContexts and its identifier there; a WebKit page's download's
// is "wk/<n>".
extension Engine: @preconcurrency ECDownloadDelegate {
  func browserContext(_ context: ECBrowserContext, downloadDidUpdate download: ECDownload) {
    Self.continuation.yield(.downloaded(Download(
      id: "\(downloadContexts.firstIndex(of: context)!)/\(download.identifier)", url: download.url,
      fileURL: download.fileURL, receivedBytes: download.receivedBytes, totalBytes: download.totalBytes,
      state: download.state, startTime: download.startTime,
      profileID: downloadProfiles[context])))
  }

  func cancelDownload(_ id: Download.ID) {
    guard !id.hasPrefix("wk/") else { return WebKitDownloads.shared.cancel(id) }
    let parts = id.split(separator: "/").compactMap { UInt32($0) }
    guard parts.count == 2, downloadContexts.indices.contains(Int(parts[0])) else { return }
    downloadContexts[Int(parts[0])].cancelDownload(parts[1])
  }
}
