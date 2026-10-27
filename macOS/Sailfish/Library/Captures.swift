import ComposableArchitecture
import OSLog
import SwiftUI

// A page capture kept for the Library's Media, with the page it was taken from.
struct Capture: Codable, Equatable, Identifiable {
  let id: UUID
  let pageURL: URL
  let title: String
  let profileID: UUID
  let capturedAt: Date

  var fileURL: URL { Captures.directory.appending(path: "\(id.uuidString).png") }
}

extension SharedKey where Self == FileStorageKey<IdentifiedArrayOf<Capture>>.Default {
  // Newest first.
  static var captures: Self { Self[.fileStorage(URL.dataDirectory.appending(path: "Captures.json")), default: []] }
}

enum Captures {
  static let directory = URL.dataDirectory.appending(path: "Captures")

  // Capture: the image goes to the clipboard and, outside incognito, into Media.
  @MainActor static func keep(_ image: NSImage, of tab: Tab, in space: Space) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
    guard !space.isIncognito, let tiff = image.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { return }
    let capture = Capture(id: UUID(), pageURL: tab.url, title: tab.displayTitle, profileID: space.profileID, capturedAt: .now)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try png.write(to: capture.fileURL, options: .atomic)
    } catch {
      Logger().error("Capture not kept: \(error)")
      return
    }
    @Shared(.captures) var captures
    $captures.withLock { $0.insert(capture, at: 0) }
  }

  @MainActor static func delete(_ capture: Capture) {
    @Shared(.captures) var captures
    $captures.withLock { _ = $0.remove(id: capture.id) }
    do {
      try FileManager.default.removeItem(at: capture.fileURL)
    } catch {
      Logger().error("Capture file not removed: \(error)")
    }
  }

  // Save…: a copy of the image where the panel says.
  @MainActor static func save(_ capture: Capture) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = capture.title.replacingOccurrences(of: "/", with: "-") + ".png"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: capture.fileURL, to: destination)
    } catch {
      Logger().error("Capture not saved: \(error)")
    }
  }
}

// The menu on a capture: its page, sharing, the file, and a permanent delete that asks first.
struct CaptureMenu: View {
  let capture: Capture
  let openPage: (URL) -> Void

  var body: some View {
    Button("Copy URL") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(capture.pageURL.absoluteString, forType: .string)
    }
    Button("Open URL") { openPage(capture.pageURL) }
    Divider()
    Button("AirDrop") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [capture.fileURL]) }
    Button("Send via iMessage") { NSSharingService(named: .composeMessage)?.perform(withItems: [capture.fileURL]) }
    Divider()
    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([capture.fileURL]) }
    Button("Save…") { Captures.save(capture) }
    Divider()
    Button("Delete") {
      guard let window = NSApp.keyWindow else { return }
      presentModal(over: window) { dismiss in
        DeleteCaptureDialog(delete: { Captures.delete(capture) }, dismiss: dismiss)
      }
    }
  }
}

// "Delete this Capture?" with the permanent-delete warning.
struct DeleteCaptureDialog: View {
  let delete: () -> Void
  let dismiss: () -> Void

  var body: some View {
    ConfirmModal(
      confirm: "Delete", confirmFill: Color(hex: 0xE8432A), confirmKeycap: Color(hex: 0xF07A66), isValid: true,
      onConfirm: {
        delete()
        dismiss()
      },
      onCancel: dismiss
    ) {
      Text("Delete this Capture?").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
      Text("The image is deleted from this computer. This cannot be undone.").font(.system(size: 14)).padding(.top, 8)
    }
    .frame(width: 450)
  }
}
