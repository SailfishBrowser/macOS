import ComposableArchitecture
import Foundation
import OSLog

// Each page's saved history: Chromium's sessionState in Sessions, or WebKit's interactionState in WebKitSessions,
// beside State.json, one file per page, written when the page closes and with each snapshot while it is open.
// Incognito pages' stays in memory, for undo. The engine saves and loads on the main actor; the session writer
// prunes from its flush, off it.
final class SessionStore: Sendable {
  // Chromium cuts an entry's page state at 1 MB; a state past this, from either engine, is left as it was.
  static let maxSize = 1 << 20
  private let directory: URL
  private let memory = LockIsolated<[UUID: Data]>([:])
  // What each file holds, so an unchanged state is not written again.
  private let written = LockIsolated<[UUID: Data]>([:])

  init(directory: URL) {
    self.directory = directory
  }

  func save(_ id: UUID, _ state: Data, inMemory: Bool) {
    guard state.count <= Self.maxSize else { return }
    if inMemory {
      memory.withValue { $0[id] = state }
      return
    }
    guard written.value[id] != state else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try state.write(to: file(id), options: .atomic)
      written.withValue { $0[id] = state }
    } catch {
      Logger().error("Saving tab history failed: \(error)")
    }
  }

  func load(_ id: UUID) -> Data? {
    if let state = memory.value[id] { return state }
    let url = file(id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return try Data(contentsOf: url)
    } catch {
      Logger().error("Reading tab history failed: \(error)")
      return nil
    }
  }

  func copy(_ id: UUID, to other: UUID) {
    guard let state = load(id) else { return }
    save(other, state, inMemory: memory.value[id] != nil)
  }

  func forget(_ id: UUID) {
    memory.withValue { $0[id] = nil }
    written.withValue { $0[id] = nil }
    let url = file(id)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      Logger().error("Removing tab history failed: \(error)")
    }
  }

  // Drops the saved histories of every other page.
  func keep(_ ids: Set<UUID>) {
    memory.withValue { $0 = $0.filter { ids.contains($0.key) } }
    written.withValue { $0 = $0.filter { ids.contains($0.key) } }
    guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
      return
    }
    for url in files {
      guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !ids.contains(id) else { continue }
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func file(_ id: UUID) -> URL {
    directory.appending(path: id.uuidString + ".session")
  }
}
