// Copyright 2026 Mantra Patel. Licensed under the Apache License 2.0.
// Adapted from Ardia's packages/ardiacore/ios/WebKitStoreRemovals.swift at a01a909; Sailfish changed it.

import Foundation
import OSLog
import WebKit

// Removes the WebKit stores of deleted profiles. A store a closing page still holds cannot be removed yet, so removal
// tries for three seconds; a store still in use then is removed at the next launch, before any store opens.
@MainActor enum WebKitStoreRemovals {
  private static let pendingFile = URL.dataDirectory.appending(path: "PendingWebKitStoreRemovals.json")

  // WebKit lists and removes stores only once it has started.
  private static let webKitStarted: Void = { _ = WKWebsiteDataStore.nonPersistent() }()

  static func remove(_ profile: UUID) async {
    guard await !remove(profile, tries: 12) else { return }
    pending.append(profile)
  }

  // Nothing holds a store at launch, so each is tried once.
  static func removePending() async {
    let profiles = pending
    guard !profiles.isEmpty else { return }
    var left: [UUID] = []
    for profile in profiles where await !remove(profile, tries: 1) {
      left.append(profile)
    }
    pending = left
  }

  private static func remove(_ profile: UUID, tries: Int) async -> Bool {
    _ = webKitStarted
    guard await WKWebsiteDataStore.allDataStoreIdentifiers.contains(profile) else { return true }
    for _ in 1..<tries {
      if (try? await WKWebsiteDataStore.remove(forIdentifier: profile)) != nil { return true }
      try? await Task.sleep(for: .milliseconds(250))
    }
    do {
      try await WKWebsiteDataStore.remove(forIdentifier: profile)
      return true
    } catch {
      Logger().error("WebKit store \(profile) still in use: \(error)")
      return false
    }
  }

  private static var pending: [UUID] {
    get { (try? Data(contentsOf: pendingFile)).flatMap { try? JSONDecoder().decode([UUID].self, from: $0) } ?? [] }
    set {
      do {
        if newValue.isEmpty {
          try? FileManager.default.removeItem(at: pendingFile)
        } else {
          try JSONEncoder().encode(newValue).write(to: pendingFile, options: .atomic)
        }
      } catch {
        Logger().error("Saving pending WebKit store removals failed: \(error)")
      }
    }
  }
}
