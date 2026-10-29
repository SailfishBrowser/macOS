import ComposableArchitecture
import Foundation

// Every save of one kind of value goes through one writer: the debounced saves (and, for the window state, the
// one at quit) write under one lock, each writes the newest value it finds there, and one that finds it already
// written does nothing. So a save descheduled before its write never writes an older value after a newer one.
final class SnapshotWriter<Value: Equatable & Sendable>: Sendable {
  // The newest value, under its own lock, so that recording one never waits on a write.
  private let latest = LockIsolated<Value?>(nil)
  // The last value written; its lock is held across reading the newest one and writing it.
  private let written = LockIsolated<Value?>(nil)
  private let write: @Sendable (Value) throws -> Void

  init(write: @escaping @Sendable (Value) throws -> Void) {
    self.write = write
  }

  func update(_ value: Value) {
    latest.setValue(value)
  }

  func flush() throws {
    try written.withValue { written in
      guard let latest = latest.value, latest != written else { return }
      try write(latest)
      written = latest
    }
  }
}

extension SnapshotWriter where Value == Snapshot {
  // State.json.
  static var state: SnapshotWriter {
    SnapshotWriter { snapshot in
      @Dependency(\.persistence) var persistence
      try persistence.save(snapshot.encoded())
    }
  }
}

extension SnapshotWriter where Value == Set<UUID> {
  // The pages whose saved history the Sessions and WebKitSessions folders keep.
  static var sessions: SnapshotWriter {
    SnapshotWriter { ids in
      @Dependency(\.webEngine) var engine
      engine.keepSessions(ids)
    }
  }
}
