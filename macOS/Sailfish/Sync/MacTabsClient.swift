import AppKit
import CloudKit
import ComposableArchitecture
import CryptoKit
import IOKit
import OSLog
import Security
import SystemConfiguration

// Publishes the Mac's spaces and tabs to the user's private iCloud database, which the iPhone app reads.
@DependencyClient
struct MacTabsClient: Sendable {
  var update: @Sendable (MacTabs) async -> Void = { _ in }
  var flush: @Sendable () async -> Void = {}
}

extension DependencyValues {
  var macTabs: MacTabsClient {
    get { self[MacTabsClient.self] }
    set { self[MacTabsClient.self] = newValue }
  }
}

extension MacTabsClient: DependencyKey {
  // Only a build signed with the iCloud provisioning profile may use the container; any other build publishes
  // nothing, since CKContainer raises an exception without the entitlement.
  static let liveValue: Self = {
    guard hasICloud else { return none }
    let publisher = MacTabsPublisher(
      container: CKContainer(identifier: "iCloud.com.harunkkhan.browser"),
      deviceID: deviceID,
      deviceName: SCDynamicStoreCopyComputerName(nil, nil)! as String
    )
    // Each icon page's favicon as a 32-pixel PNG; a page without one is asked again at the next update.
    let icons = LockIsolated<[URL: Data]>([:])
    return Self(
      update: { tabs in
        @Dependency(\.autocomplete) var autocomplete
        var resolved: [URL: Data] = [:]
        var asked: Set<URL> = []
        for entry in tabs.spaces {
          for page in entry.pinned + entry.tabs where asked.insert(page.iconPage).inserted {
            if let icon = icons.value[page.iconPage] {
              resolved[page.iconPage] = icon
            } else {
              resolved[page.iconPage] = await autocomplete.favicon(entry.profileID, false, page.iconPage).flatMap(png)
            }
          }
        }
        let found = resolved
        icons.setValue(found)
        // A newer state's update has replaced this one.
        guard !Task.isCancelled else { return }
        let page = { (page: MacTabs.Page) in
          MacSpace.Page(url: page.url, title: page.title, icon: found[page.iconPage])
        }
        await publisher.update(
          tabs.spaces.map {
            MacTabsPublisher.Published(
              id: $0.id, space: MacSpace(name: $0.name, pinned: $0.pinned.map(page), tabs: $0.tabs.map(page)))
          },
          current: tabs.current
        )
      },
      flush: { await publisher.flush() }
    )
  }()
  static let testValue = none

  private static let none = Self(update: { _ in }, flush: {})

  // The entitlement's value is the array of containers.
  private static var hasICloud: Bool {
    SecTaskCreateFromSelf(nil).flatMap {
      SecTaskCopyValueForEntitlement($0, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
    } != nil
  }

  // Derived from the hardware, so a reinstall or a wiped data folder reuses the Mac's records, and Migration
  // Assistant cannot carry them to another Mac; the hash keeps the hardware UUID out of iCloud.
  private static var deviceID: String {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    let platform = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
      .takeRetainedValue() as! String
    IOObjectRelease(service)
    return SHA256.hash(data: Data("sailfish-mac-tabs:\(platform)".utf8)).prefix(16)
      .map { String(format: "%02x", $0) }.joined()
  }

  private static func png(_ image: NSImage) -> Data? {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
  }
}

// Writes the Device record and one Space record per space into the zone MacTabs. The first update of a launch
// publishes at once; later ones within 3 seconds go out together, as the newest value then.
actor MacTabsPublisher {
  struct Published: Equatable, Sendable {
    let id: Space.ID
    let space: MacSpace
  }

  private struct Value {
    let spaces: [Published]
    let current: Space.ID?
  }

  // The per-item errors of a request, which CloudKit returns in its results.
  private struct ItemErrors: Error {
    let errors: [Error]
  }

  private static let spaceBytes = 400_000
  private static let requestBytes = 1_500_000
  private static let requestRecords = 400

  private let database: CKDatabase
  private let container: CKContainer
  private let zone = CKRecordZone(zoneName: "MacTabs")
  private let deviceID: String
  private let deviceName: String
  private var latest: Value?
  private var isPending = false
  private var isFirstUpdate = true
  private var isAccountChanged = false
  private var scheduled: Task<Void, Never>?
  private var retry: Task<Void, Never>?
  // The publish running or queued last; each waits for the one before it.
  private var running: Task<Void, Never>?
  // The Space record names on the server, nil until the zone is saved and the Device record read.
  private var owned: Set<String>?
  // What each Space record on the server was last published with, where known.
  private var sent: [String: MacSpace] = [:]

  init(container: CKContainer, deviceID: String, deviceName: String) {
    self.container = container
    database = container.privateCloudDatabase
    self.deviceID = deviceID
    self.deviceName = deviceName
    _ = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
    ) { [weak self] _ in
      Task { await self?.flush() }
    }
    _ = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
      Task { await self?.accountChanged() }
    }
  }

  func update(_ spaces: [Published], current: Space.ID?) {
    latest = Value(spaces: spaces, current: current)
    isPending = true
    if isFirstUpdate {
      isFirstUpdate = false
      Task { await publish(isRetry: false) }
    } else if scheduled == nil {
      scheduled = Task {
        try? await Task.sleep(for: .seconds(3))
        scheduled = nil
        await publish(isRetry: false)
      }
    }
  }

  func flush() async {
    await publish(isRetry: false)
  }

  private func accountChanged() async {
    isAccountChanged = true
    isPending = latest != nil
    await publish(isRetry: false)
  }

  private func publish(isRetry: Bool) async {
    let previous = running
    let task = Task {
      await previous?.value
      await send(isRetry: isRetry)
    }
    running = task
    await task.value
  }

  private func send(isRetry: Bool) async {
    if isAccountChanged {
      isAccountChanged = false
      owned = nil
      sent = [:]
    }
    guard isPending, let value = latest else { return }
    isPending = false
    do {
      guard try await container.accountStatus() == .available else {
        isPending = true
        return
      }
      var owned = try await prepare()
      let names = value.spaces.map { recordName($0.id) }
      var saves: [(record: CKRecord, space: MacSpace, bytes: Int)] = []
      for (published, name) in zip(value.spaces, names) {
        let (space, content) = try Self.fitted(published.space)
        guard sent[name] != space else { continue }
        let record = CKRecord(recordType: "Space", recordID: recordID(name))
        record.encryptedValues["content"] = content
        saves.append((record, space, content.count))
      }
      let device = CKRecord(recordType: "Device", recordID: recordID(deviceID))
      device.encryptedValues["name"] = deviceName
      device["spaces"] = names
      device["current"] = value.current.map(recordName)
      let deletions = owned.subtracting(names)

      // Space saves first, within CloudKit's request limits; the Device record and the deletions go last, so a
      // space is listed only once its record is there.
      var requests: [[(record: CKRecord, space: MacSpace?)]] = [[]]
      var bytes = 0
      for save in saves {
        if !requests[requests.count - 1].isEmpty
          && (requests[requests.count - 1].count == Self.requestRecords || bytes + save.bytes > Self.requestBytes)
        {
          requests.append([])
          bytes = 0
        }
        requests[requests.count - 1].append((save.record, save.space))
        bytes += save.bytes
      }
      if requests[requests.count - 1].count + 1 + deletions.count > Self.requestRecords {
        requests.append([])
      }
      requests[requests.count - 1].append((device, nil))

      for (index, request) in requests.enumerated() {
        let isLast = index == requests.count - 1
        try await modify(request.map(\.record), deleting: isLast ? deletions.map(recordID) : [])
        for (record, space) in request {
          guard let space else { continue }
          owned.insert(record.recordID.recordName)
          sent[record.recordID.recordName] = space
        }
        if isLast {
          owned.subtract(deletions)
          deletions.forEach { sent[$0] = nil }
        }
        self.owned = owned
      }
    } catch {
      isPending = true
      let errors = Self.errors(error)
      Logger().error("Publishing tabs to iCloud failed: \(String(describing: errors), privacy: .public)")
      let isZoneGone = errors.contains { ($0 as? CKError).map { [.zoneNotFound, .userDeletedZone].contains($0.code) } ?? false }
      if isZoneGone {
        owned = nil
        sent = [:]
      }
      let delay = isZoneGone ? 0 : errors.compactMap { ($0 as? CKError)?.retryAfterSeconds }.max()
      if !isRetry, retry == nil, let delay {
        retry = Task {
          try? await Task.sleep(for: .seconds(delay))
          retry = nil
          await publish(isRetry: true)
        }
      }
    }
  }

  // Saves the zone, which succeeds when it exists, and learns the Space records the Device record lists.
  private func prepare() async throws -> Set<String> {
    if let owned { return owned }
    let (saved, _) = try await database.modifyRecordZones(saving: [zone], deleting: [])
    _ = try saved[zone.zoneID]?.get()
    let listed: [String]
    do {
      // CloudKit drops an empty list, so a Device record without one lists none.
      listed = try await database.record(for: recordID(deviceID))["spaces"] ?? []
    } catch let error as CKError where error.code == .unknownItem {
      listed = []
    }
    owned = Set(listed)
    sent = [:]
    return Set(listed)
  }

  private func modify(_ saving: [CKRecord], deleting: [CKRecord.ID]) async throws {
    let (saved, deleted) = try await database.modifyRecords(
      saving: saving, deleting: deleting, savePolicy: .allKeys, atomically: true)
    let errors: [Error] =
      saved.values.compactMap { if case let .failure(error) = $0 { error } else { nil } }
      + deleted.values.compactMap { if case let .failure(error) = $0 { error } else { nil } }
    if !errors.isEmpty { throw ItemErrors(errors: errors) }
  }

  private static func errors(_ error: Error) -> [Error] {
    switch error {
    case let error as ItemErrors: error.errors
    case let error as CKError where error.code == .partialFailure: error.partialErrorsByItemID.map { Array($0.values) } ?? [error]
    default: [error]
    }
  }

  // A space over the size cap loses its icons, then tabs from the end until it fits.
  private static func fitted(_ space: MacSpace) throws -> (MacSpace, Data) {
    let content = try JSONEncoder().encode(space)
    guard content.count > spaceBytes else { return (space, content) }
    func bare(_ pages: some Collection<MacSpace.Page>) -> [MacSpace.Page] {
      pages.map { MacSpace.Page(url: $0.url, title: $0.title, icon: nil) }
    }
    func trimmed(_ count: Int) -> MacSpace {
      MacSpace(name: space.name, pinned: bare(space.pinned), tabs: bare(space.tabs.prefix(count)))
    }
    var low = 0
    var high = space.tabs.count
    while low < high {
      let mid = (low + high + 1) / 2
      if try JSONEncoder().encode(trimmed(mid)).count <= spaceBytes { low = mid } else { high = mid - 1 }
    }
    return (trimmed(low), try JSONEncoder().encode(trimmed(low)))
  }

  private func recordName(_ space: Space.ID) -> String {
    "\(deviceID).\(space.uuidString)"
  }

  private func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zone.zoneID)
  }
}
