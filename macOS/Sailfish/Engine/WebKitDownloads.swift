// Copyright 2026 Mantra Patel. Licensed under the Apache License 2.0.
// Adapted from Ardia's packages/ardiacore/ios/WebKitDownloads.swift at a01a909; Sailfish changed it.

import AppKit
@preconcurrency import EngineCore
import WebKit

// WebKit pages' downloads, reported to the downloads list as the engine's are, with ids "wk/<n>". A download is
// written into a hidden staging folder beside its destination and moved into place under a unique name when it
// finishes, so a partial file never shows under the final name. WebKit keeps no download history, so the finished
// downloads of regular profiles are saved and reported again when their profile loads.
@MainActor final class WebKitDownloads: NSObject, WKDownloadDelegate {
  static let shared = WebKitDownloads()
  private static let file = URL.dataDirectory.appending(path: "WebKitDownloads.json")
  private static let stagingPrefix = ".sailfish-download-"
  private static let writer = DispatchQueue(label: "WebKitDownloads")

  private final class Item {
    var download: Download
    let profile: UUID
    let incognito: Bool
    // Asks where to save: Save Link As, Save Image As, and every incognito download.
    let asks: Bool
    var task: WKDownload?
    var destination: URL?
    var staging: URL?
    var progress: NSKeyValueObservation?
    var reportedAt = ContinuousClock.now

    init(download: Download, profile: UUID, incognito: Bool, asks: Bool) {
      self.download = download
      self.profile = profile
      self.incognito = incognito
      self.asks = asks
    }
  }

  private struct Saved: Codable {
    let id: String
    let url: URL
    let fileURL: URL
    let bytes: Int64
    let startTime: Date
    let profile: UUID
  }

  // Running downloads by id, and each one's id by its WebKit download.
  private var items: [Download.ID: Item] = [:]
  private var ids: [ObjectIdentifier: Download.ID] = [:]
  private var saved: [Saved]
  // The number in the last id given, counting the saved downloads' ids.
  private var lastNumber: Int

  private override init() {
    saved = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
    lastNumber = saved.compactMap { Int($0.id.dropFirst(3)) }.max() ?? 0
  }

  // A download of a page that asks the profile's download folder, or asks where to save.
  static func isDownload(_ action: WKNavigationAction) -> Bool {
    action.shouldPerformDownload
      || action.navigationType == .linkActivated
        && action.modifierFlags.intersection([.command, .shift, .option, .control]) == .option
  }

  // A response WebKit cannot show, or one the server marks as an attachment.
  static func isDownload(_ response: WKNavigationResponse) -> Bool {
    let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
    return !response.canShowMIMEType || disposition?.lowercased().hasPrefix("attachment") == true
  }

  func adopt(_ task: WKDownload, profile: UUID, incognito: Bool, asks: Bool) {
    guard let url = task.originalRequest?.url else { return task.cancel(nil) }
    lastNumber += 1
    let download = Download(
      id: "wk/\(lastNumber)", url: url, fileURL: nil, receivedBytes: 0, totalBytes: 0, state: .inProgress,
      startTime: .now, profileID: profile)
    let item = Item(download: download, profile: profile, incognito: incognito, asks: asks || incognito)
    item.task = task
    items[download.id] = item
    ids[ObjectIdentifier(task)] = download.id
    task.delegate = self
    item.progress = task.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
      let received = progress.completedUnitCount
      let total = max(0, progress.totalUnitCount)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.progressed(download.id, received: received, total: total) }
      }
    }
  }

  func cancel(_ id: Download.ID) {
    guard let item = items[id] else { return }
    let staging = item.staging
    item.task?.cancel { _ in staging.map { try? FileManager.default.removeItem(at: $0) } }
    end(item, .cancelled)
  }

  // Cancels the profile's downloads and forgets the finished ones, as its profile is deleted.
  func forget(profile: UUID) {
    items.values.filter { $0.profile == profile }.forEach { cancel($0.download.id) }
    saved.removeAll { $0.profile == profile }
    save()
  }

  // The profile's finished downloads, again, now that it has loaded.
  func report(profile: UUID) {
    for entry in saved where entry.profile == profile {
      Engine.continuation.yield(.downloaded(Download(
        id: entry.id, url: entry.url, fileURL: entry.fileURL, receivedBytes: entry.bytes, totalBytes: entry.bytes,
        state: .complete, startTime: entry.startTime, profileID: entry.profile)))
    }
  }

  func download(
    _ task: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
    completionHandler: @escaping @MainActor (URL?) -> Void
  ) {
    guard let item = item(task) else { return completionHandler(nil) }
    guard let folder = Engine.shared.contexts[item.profile]?.downloadDirectory else {
      detach(item)
      return completionHandler(nil)
    }
    // A download cancelled while its save panel was open stays cancelled.
    let accept = { [weak self] (destination: URL?) in
      guard let self, let destination, items[item.download.id] === item else {
        self?.detach(item)
        return completionHandler(nil)
      }
      let staging = destination.deletingLastPathComponent()
        .appending(path: Self.stagingPrefix + UUID().uuidString, directoryHint: .isDirectory)
      guard (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil else {
        completionHandler(nil)
        return end(item, .interrupted)
      }
      item.destination = destination
      item.staging = staging
      item.download.fileURL = destination
      item.download.totalBytes = max(0, response.expectedContentLength)
      Engine.continuation.yield(.downloaded(item.download))
      completionHandler(staging.appending(path: destination.lastPathComponent))
    }
    let name = Self.safeName(suggestedFilename)
    guard item.asks else { return accept(folder.appending(path: name)) }
    let panel = NSSavePanel()
    panel.directoryURL = folder
    panel.nameFieldStringValue = name
    // The page may have closed since the download started.
    if let window = task.webView?.window {
      panel.beginSheetModal(for: window) { accept($0 == .OK ? panel.url : nil) }
    } else {
      panel.begin { accept($0 == .OK ? panel.url : nil) }
    }
  }

  func downloadDidFinish(_ task: WKDownload) {
    guard let item = item(task), let staging = item.staging, let destination = item.destination else { return }
    // A destination chosen in the save panel was confirmed there, so it is replaced; any other gets a unique name.
    let placed = Self.place(
      staging.appending(path: destination.lastPathComponent), at: destination, replacing: item.asks)
    try? FileManager.default.removeItem(at: staging)
    guard let placed else { return end(item, .interrupted) }
    let size = (try? placed.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? item.download.receivedBytes
    item.download.fileURL = placed
    item.download.receivedBytes = size
    item.download.totalBytes = size
    end(item, .complete)
    guard !item.incognito else { return }
    saved.append(Saved(
      id: item.download.id, url: item.download.url, fileURL: placed, bytes: size, startTime: item.download.startTime,
      profile: item.profile))
    save()
  }

  func download(_ task: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    guard let item = item(task) else { return }
    item.staging.map { try? FileManager.default.removeItem(at: $0) }
    end(item, (error as NSError).code == NSURLErrorCancelled ? .cancelled : .interrupted)
  }

  private func item(_ task: WKDownload) -> Item? {
    ids[ObjectIdentifier(task)].flatMap { items[$0] }
  }

  // Reported at most four times a second while running.
  private func progressed(_ id: Download.ID, received: Int64, total: Int64) {
    guard let item = items[id], item.download.fileURL != nil else { return }
    item.download.receivedBytes = received
    item.download.totalBytes = total
    guard ContinuousClock.now - item.reportedAt >= .milliseconds(250) else { return }
    item.reportedAt = .now
    Engine.continuation.yield(.downloaded(item.download))
  }

  // The download's last report, once it is shown in the list.
  private func end(_ item: Item, _ state: ECDownloadState) {
    detach(item)
    item.download.state = state
    if item.download.fileURL != nil {
      Engine.continuation.yield(.downloaded(item.download))
    }
  }

  private func detach(_ item: Item) {
    item.progress = nil
    item.task.map { ids[ObjectIdentifier($0)] = nil }
    item.task = nil
    items[item.download.id] = nil
  }

  private func save() {
    let data = try? JSONEncoder().encode(saved)
    Self.writer.async { try? data?.write(to: Self.file, options: .atomic) }
  }

  // Moves the finished file to its destination, or to "name (1).ext" and on as Chrome numbers them when it is
  // taken; nil when it cannot be moved.
  private static func place(_ file: URL, at destination: URL, replacing: Bool) -> URL? {
    if replacing {
      return rename(file.path, destination.path) == 0 ? destination : nil
    }
    let base = destination.deletingPathExtension().lastPathComponent
    let ext = destination.pathExtension
    for n in 0...9999 {
      let name = n == 0 ? destination.lastPathComponent : ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
      let candidate = destination.deletingLastPathComponent().appending(path: name)
      if renamex_np(file.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
      if errno != EEXIST { return nil }
    }
    return nil
  }

  // The suggested name made safe for a folder: no path separators, and no leading dots that would hide it.
  private static func safeName(_ name: String) -> String {
    let cleaned = name.replacing("/", with: "_").replacing(":", with: "_")
      .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
    return cleaned.isEmpty ? "download" : cleaned
  }
}

extension WebKitPage {
  func webView(
    _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
    decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
  ) {
    decisionHandler(WebKitDownloads.isDownload(response) ? .download : .allow)
  }

  func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
    WebKitDownloads.shared.adopt(download, profile: profile, incognito: incognito, asks: false)
  }

  func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
    WebKitDownloads.shared.adopt(download, profile: profile, incognito: incognito, asks: false)
  }

  // Downloads the link's or image's target, asking where to save it, for Save Link As and Save Image As.
  func saveTarget(_ url: URL) {
    webView.startDownload(using: URLRequest(url: url)) { [profile, incognito] in
      WebKitDownloads.shared.adopt($0, profile: profile, incognito: incognito, asks: true)
    }
  }
}
