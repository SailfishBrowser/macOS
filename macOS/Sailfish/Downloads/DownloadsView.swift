import ComposableArchitecture
import QuickLookThumbnailing
import SwiftUI

// The download badge: a lavender disc with a glow, whose ring fills with the progress around a down arrow.
struct DownloadRing: View {
  let progress: Double
  var size: CGFloat = 20

  var body: some View {
    ZStack {
      Circle().fill(Theme.accentTint).shadow(color: Theme.accent.opacity(0.4), radius: 3)
      Circle().stroke(Theme.accent.opacity(0.25), lineWidth: 2)
      Circle().trim(from: 0, to: progress).stroke(Theme.accent, lineWidth: 2).rotationEffect(.degrees(-90))
      Image(systemName: "arrow.down").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(Theme.accent)
    }
    .frame(width: size, height: size)
  }
}

extension Download {
  var progress: Double { totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0 }

  // The status line: "7.3/20.0 MB · 21s" while it downloads, then its age, or how it ended.
  func status(_ now: Date) -> String {
    switch state {
    case .inProgress:
      // Both sizes in the total's unit: "7.3/20.0 MB".
      let (unit, divisor): (String, Double) = totalBytes >= 1_000_000_000 ? ("GB", 1e9) : ("MB", 1e6)
      let amount = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / divisor) }
      guard totalBytes > 0 else { return "\(amount(receivedBytes)) \(unit)" }
      let sizes = "\(amount(receivedBytes))/\(amount(totalBytes)) \(unit)"
      let elapsed = now.timeIntervalSince(startTime)
      guard receivedBytes > 0, elapsed > 0 else { return sizes }
      let left = Double(totalBytes - receivedBytes) / (Double(receivedBytes) / elapsed)
      return "\(sizes) · \(Duration.seconds(Int(left)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 1)))"
    case .complete:
      return startTime.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
    case .cancelled: return "Cancelled"
    default: return "Failed"
    }
  }
}

extension IdentifiedArrayOf<Download> {
  // All running downloads' progress as one, by bytes; nil when none runs.
  var progress: Double? {
    let running = filter { $0.state == .inProgress }
    guard !running.isEmpty else { return nil }
    let total = running.map(\.totalBytes).reduce(0, +)
    return total > 0 ? Double(running.map(\.receivedBytes).reduce(0, +)) / Double(total) : 0
  }
}

extension View {
  // A finished download drags out of the browser as its file.
  @ViewBuilder func draggableFile(_ download: Download) -> some View {
    if download.state == .complete, let file = download.fileURL {
      onDrag { NSItemProvider(object: file as NSURL) }
    } else {
      self
    }
  }
}

// The download menus, shared by every list. The sidebar's stack has the full one; the Library's ⋯ menu is the
// short one: Open, Copy and Show in Finder. Both end with Hide and Move to Trash.
struct DownloadMenu: View {
  let download: Download
  var isShort = false
  @Environment(StoreOf<DownloadsFeature>.self) private var downloads

  var body: some View {
    if download.state == .inProgress {
      Button("Cancel") { downloads.send(.cancel(download.id)) }
    } else {
      if let file = download.fileURL, download.state == .complete {
        // "Copy PDF" for a PDF, "Copy File" for anything else.
        let noun = download.type.conforms(to: .pdf) ? "PDF" : "File"
        let copy = Button("Copy \(noun)") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.writeObjects([file as NSURL])
        }
        let finder = Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        if isShort {
          Button("Open \(noun)") { NSWorkspace.shared.open(file) }
          copy
          finder
        } else {
          copy
          Divider()
          share(file, .composeMessage, "Send via iMessage")
          share(file, .sendViaAirDrop, "AirDrop")
          Divider()
          // Names the app the file opens in: "Open in Preview".
          let app = NSWorkspace.shared.urlForApplication(toOpen: file)
          Button(app.map { "Open in \($0.deletingPathExtension().lastPathComponent)" } ?? "Open") {
            NSWorkspace.shared.open(file)
          }
          finder
        }
        Divider()
      }
      Button("Hide from Sailfish") { downloads.send(.hide(download.id)) }
      if download.state == .complete, download.fileURL != nil {
        Button("Move to Trash") { downloads.send(.moveToTrash(download.id)) }
      }
    }
  }

  @ViewBuilder private func share(_ file: URL, _ name: NSSharingService.Name, _ title: String) -> some View {
    if let service = NSSharingService(named: name), service.canPerform(withItems: [file]) {
      Button(title) { service.perform(withItems: [file]) }
    }
  }
}

// A row of the stack the Library button shows: the file's thumbnail, name and age, or its progress
// with an × that cancels it.
struct DownloadRow: View {
  let download: Download
  let cancel: () -> Void
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 12) {
      Group {
        if download.state == .inProgress {
          DownloadRing(progress: download.progress, size: 24)
        } else {
          FileThumbnail(download: download)
        }
      }
      .frame(width: 40, height: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text(download.name).font(.system(size: 14)).lineLimit(1)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(download.status(context.date)).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      if download.state == .inProgress {
        Button(action: cancel) {
          Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.icon)
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Cancel")
      }
    }
    // Rows 56 pt apart around 40 pt thumbnails.
    .padding(.horizontal, 6)
    .padding(.vertical, 8)
    .background(isHovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .draggableFile(download)
    .onTapGesture {
      guard download.state == .complete, let file = download.fileURL else { return }
      NSWorkspace.shared.open(file)
    }
    .contextMenu { DownloadMenu(download: download) }
  }
}

// QuickLook's thumbnail of a finished download, else the icon of its kind of file.
struct FileThumbnail: View {
  let download: Download
  @State private var thumbnail: NSImage?

  var body: some View {
    Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(for: download.type))
      .resizable()
      .aspectRatio(contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .task(id: download.fileURL) {
        guard download.state == .complete, let file = download.fileURL else { return }
        let request = QLThumbnailGenerator.Request(
          fileAt: file, size: CGSize(width: 80, height: 80), scale: 2, representationTypes: .thumbnail)
        thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
      }
  }
}
