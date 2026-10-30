import ComposableArchitecture
import QuickLook
import QuickLookThumbnailing
import SwiftUI

// The Library: an icon rail and a column in place of the sidebar, in the space's theme, beside the page.
struct LibraryView: View {
  @Bindable var store: StoreOf<LibraryFeature>
  let window: StoreOf<WindowFeature>
  @Environment(StoreOf<DownloadsFeature>.self) private var downloads
  @State private var selection: Download.ID?
  // The file the Quick Look preview shows, opened by a click on a download.
  @State private var preview: URL?
  @Shared(.archive) private var archive
  @Shared(.captures) private var captures
  @Shared(.mediaSources) private var sources
  @Shared(.hiddenMedia) private var hiddenMedia
  @Shared(.firstLaunch) private var firstLaunch
  @Shared(.mediaFoldersAsked) private var mediaFoldersAsked
  @State private var folderMedia: [(url: URL, date: Date)] = []

  var body: some View {
    HStack(spacing: 0) {
      rail.frame(width: 113)
      switch store.pane {
      case .media:
        column(placeholder: "Search Media...", hasFilter: false) {
          if mediaItems(query: "").isEmpty {
            empty("photo.on.rectangle", "No Media")
          } else {
            mediaGrid
          }
        }
        // The Library stays alive while closed, so the folders are read and watched only while it is open on Media,
        // and only once their access prompts were raised, so that it never raises one itself.
        .task(id: window.isLibraryOpen && mediaFoldersAsked ? sources.rawValue : nil) {
          guard window.isLibraryOpen, mediaFoldersAsked, let firstLaunch else { return }
          let folders = MediaSources.allCases.filter { sources.contains($0) }.compactMap(\.folder)
          for await media in LibraryFeature.media(in: folders, since: firstLaunch) {
            folderMedia = media
          }
        }
      case .downloads:
        column(placeholder: "Search Downloads...", hasFilter: true) { downloadList }
      case .spaces:
        LibrarySpaces(window: window)
      case .archive:
        column(placeholder: "Search Archive...", hasFilter: true) {
          if archive.isEmpty {
            empty("archivebox", "No Archived Tabs")
          } else {
            archiveList
          }
        }
      }
    }
    .foregroundStyle(Theme.primaryText)
  }

  private var rail: some View {
    VStack(spacing: 20) {
      TrafficLights().padding(.leading, -5).frame(maxWidth: .infinity, alignment: .leading).frame(height: 54).padding(.bottom, 34)
      RailItem(title: "Media", systemName: "photo.on.rectangle.angled", isSelected: store.pane == .media) {
        store.send(.select(.media))
      }
      RailItem(title: "Downloads", systemName: "arrow.down.circle", isSelected: store.pane == .downloads) {
        store.send(.select(.downloads))
      }
      RailItem(title: "Spaces", systemName: "rectangle.on.rectangle.angled", isSelected: store.pane == .spaces) {
        store.send(.select(.spaces))
      }
      RailItem(title: "Archived Tabs", systemName: "archivebox", isSelected: store.pane == .archive) {
        store.send(.select(.archive))
      }
      Spacer()
      HStack {
        RailButton(systemName: "arrow.left", help: "Back") { window.send(.toggleLibrary) }
        Spacer()
        RailButton(systemName: "gift", help: "Share Sailfish") { share() }
      }
      .padding(.horizontal, 2)
      .frame(height: 50)
    }
    .padding(.horizontal, 8)
  }

  private func column<Content: View>(
    placeholder: String, hasFilter: Bool, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
          TextField("", text: $store.query, prompt: Text(placeholder).foregroundStyle(.secondary))
            .textFieldStyle(.plain)
            .font(.system(size: 14))
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
        if hasFilter {
          Menu {
            Picker("Profiles", selection: $store.profile) {
              Text("All Profiles").tag(Profile.ID?.none)
              ForEach(window.spaces.profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
          } label: {
            Label(store.profile.flatMap { window.spaces.profiles[id: $0]?.name } ?? "Filter", systemImage: "line.3.horizontal.decrease.circle")
              .font(.system(size: 14, weight: .medium))
          }
          .menuStyle(.button)
          .buttonStyle(.plain)
          .menuIndicator(.hidden)
          .padding(.horizontal, 10)
          .frame(height: 36)
          .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
          .fixedSize()
        }
      }
      .padding(.top, 10)
      content()
    }
    .padding(.horizontal, 7)
    .frame(width: 304)
  }

  private var downloadList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        let groups = LibraryFeature.groups(
          Array(downloads.downloads), query: store.query, profile: store.profile, now: .now, calendar: .current)
        ForEach(groups, id: \.title) { group in
          Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 6)
          ForEach(group.downloads) { download in
            LibraryDownloadRow(download: download, isSelected: selection == download.id) {
              downloads.send(.cancel(download.id))
            }
              .onTapGesture(count: 2) { download.fileURL.map { _ = NSWorkspace.shared.open($0) } }
              .onTapGesture {
                selection = download.id
                preview = download.state == .complete ? download.fileURL : nil
              }
          }
        }
      }
    }
    .scrollIndicators(.never)
    .quickLookPreview($preview, in: downloads.downloads.filter { $0.state == .complete }.compactMap(\.fileURL))
  }

  // Clicking an archived tab opens it again in the current space.
  private var archiveList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        let groups = LibraryFeature.groups(
          Array(archive), query: store.query, profile: store.profile, now: .now, calendar: .current)
        ForEach(groups, id: \.title) { group in
          Text(group.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.top, 18).padding(.bottom, 6)
          ForEach(group.items) { tab in
            ArchivedTabRow(tab: tab) { window.send(.restoreArchived(tab.id)) }
          }
        }
      }
    }
    .scrollIndicators(.never)
  }

  private typealias MediaItem = (id: String, file: URL, date: Date, capture: Capture?)

  // Media: captures, and the images and videos in the folders "Show media from:" picks or downloaded, newest
  // first.
  private func mediaItems(query: String) -> [MediaItem] {
    let matches = { (text: String) in query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    let shots = sources.contains(.captures) ? captures.filter { matches($0.title) || matches($0.pageURL.absoluteString) } : []
    let downloaded =
      sources.contains(.downloads)
      ? LibraryFeature.media(Array(downloads.downloads), query: query).filter {
        $0.fileURL.map { !folderMedia.map(\.url).contains($0) } ?? false
      } : []
    let items: [MediaItem] =
      shots.map { ($0.id.uuidString, $0.fileURL, $0.capturedAt, $0) }
      + downloaded.map { ($0.id, $0.fileURL!, $0.startTime, nil) }
      + folderMedia.filter { matches($0.url.lastPathComponent) }.map { ($0.url.path, $0.url, $0.date, nil) }
    return items.filter { !hiddenMedia.contains($0.file) }.sorted { $0.date > $1.date }
  }

  // Tiles two to a row. A double click opens the file; a capture keeps its menu, and any other file has the media menu.
  private var mediaGrid: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
        ForEach(mediaItems(query: store.query), id: \.id) { item in
          MediaTile(file: item.file)
            .onTapGesture(count: 2) { NSWorkspace.shared.open(item.file) }
            .contextMenu {
              if let capture = item.capture {
                CaptureMenu(capture: capture) { url in
                  window.send(.tab(.open(url), in: window.spaces.selectedID))
                  window.send(.toggleLibrary)
                }
              } else {
                MediaMenu(file: item.file) { _ = $hiddenMedia.withLock { $0.insert(item.file) } }
              }
            }
        }
      }
      .padding(.top, 10)
    }
    .scrollIndicators(.never)
  }

  private func empty(_ symbol: String, _ title: String) -> some View {
    VStack(spacing: 10) {
      Spacer()
      Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(.secondary)
      Text(title).font(.system(size: 17, weight: .semibold))
      Spacer()
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity)
  }

  private func share() {
    guard let window = NSApp.keyWindow else { return }
    presentModal(over: window) { ShareSailfish(dismiss: $0) }
  }
}

private struct RailItem: View {
  let title: String
  let systemName: String
  let isSelected: Bool
  let action: () -> Void
  @State private var isHovering = false
  // The rail icons play their animation on hover and when their pane opens.
  @State private var bounces = 0

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        // The open pane's icon is filled in the accent, its inner glyph white. The archive box's fill has
        // one layer, so it is all accent.
        Image(systemName: systemName).font(.system(size: 20)).symbolEffect(.bounce, value: bounces)
          .symbolVariant(isSelected ? .fill : .none)
          .symbolRenderingMode(isSelected ? .palette : .monochrome)
          .foregroundStyle(
            isSelected ? systemName == "archivebox" ? Theme.accent : .white : Theme.secondaryText,
            Theme.accent)
        Text(title).font(.system(size: 11, weight: .semibold))
          .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 80)
      .background(
        isSelected ? Theme.fill : isHovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 10))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover {
      isHovering = $0
      if $0 { bounces += 1 }
    }
    .onChange(of: isSelected) { if isSelected { bounces += 1 } }
  }
}

private struct RailButton: View {
  let systemName: String
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.secondaryText)
        .frame(width: 28, height: 28).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}

private struct LibraryDownloadRow: View {
  let download: Download
  let isSelected: Bool
  let cancel: () -> Void
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 12) {
      Group {
        if download.state == .inProgress {
          DownloadRing(progress: download.progress)
        } else {
          FileThumbnail(download: download)
        }
      }
      .frame(width: 24, height: 32)
      VStack(alignment: .leading, spacing: 1) {
        Text(download.name).font(.system(size: 14)).lineLimit(1)
        // A download still running, cancelled or failed shows how far it got, as in the Library button's stack.
        Group {
          switch download.state {
          case .inProgress:
            TimelineView(.periodic(from: .now, by: 1)) { context in Text(download.status(context.date)) }
          case .complete:
            Text(download.subtitle)
          default:
            Text(download.status(.now))
          }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      if download.state == .inProgress {
        Button(action: cancel) {
          Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.icon)
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Cancel")
      } else if isHovering {
        // The More Options button: the Library's menu for the download.
        Menu {
          DownloadMenu(download: download, isShort: true)
        } label: {
          Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.icon)
            .frame(width: 28, height: 28).background(Theme.hover, in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More Options")
      }
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    .background(
      isSelected ? Theme.fill : isHovering ? Theme.hover : .clear,
      in: RoundedRectangle(cornerRadius: 8))
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .draggableFile(download)
  }
}

// A click or the hover's Restore button reopens the tab; Delete drops it from the archive.
private struct ArchivedTabRow: View {
  let tab: ArchivedTab
  let restore: () -> Void
  @State private var favicon: NSImage?
  @State private var isHovering = false
  @Shared(.profiles) private var profiles
  @Shared(.archive) private var archive

  var body: some View {
    HStack(spacing: 12) {
      Group {
        if let favicon {
          Image(nsImage: favicon).resizable()
        } else {
          RoundedRectangle(cornerRadius: 4).fill(Theme.fill)
        }
      }
      .frame(width: 16, height: 16)
      .frame(width: 24)
      VStack(alignment: .leading, spacing: 1) {
        Text(tab.title).font(.system(size: 14)).lineLimit(1)
        if tab.url.host() != nil {
          Text(tab.url.absoluteString.replacing(/^https?:\/\/(www\.)?/, with: "").replacing(/\/$/, with: ""))
            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      if isHovering {
        button("arrow.uturn.left", help: "Restore", action: restore)
        button("trash", help: "Delete", action: delete)
      }
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    .background(isHovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
    .onTapGesture(perform: restore)
    .contextMenu {
      Button("Restore", action: restore)
      Button("Delete", action: delete)
    }
    .task {
      // A deleted profile's data is gone, so its tabs have no favicon.
      guard profiles[id: tab.profileID] != nil else { return }
      favicon = await Autocomplete.favicon(tab.profileID, false, tab.url)
    }
  }

  private func delete() {
    _ = $archive.withLock { $0.remove(id: tab.id) }
  }

  private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.icon)
        .frame(width: 24, height: 24).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}

extension Download {
  // "PDF from discordapp.com", "Image from sail.fish" or "Download from googleusercontent.com".
  var subtitle: String {
    let kind =
      type.conforms(to: .pdf) ? "PDF" : type.conforms(to: .image) ? "Image" : type.conforms(to: .movie) ? "Video" : "Download"
    guard url.host() != nil else { return kind }
    return "\(kind) from \(url.domain)"
  }
}

// A Media tile: the file's thumbnail centered on a slightly darker square.
private struct MediaTile: View {
  let file: URL
  @State private var thumbnail: NSImage?

  var body: some View {
    Group {
      if let thumbnail {
        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 4))
      } else {
        Color.clear
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .aspectRatio(1, contentMode: .fit)
    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))
    .task(id: file) {
      let request = QLThumbnailGenerator.Request(
        fileAt: file, size: CGSize(width: 280, height: 280), scale: 2, representationTypes: .thumbnail)
      thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
  }
}

// The menu on a screenshot, a downloaded image or one from a folder.
private struct MediaMenu: View {
  let file: URL
  let hide: () -> Void

  var body: some View {
    let isImage = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) ?? false
    Button(isImage ? "Copy Image" : "Copy Video") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects(isImage ? [NSImage(contentsOf: file)].compactMap { $0 } : [file as NSURL])
    }
    Divider()
    Button("Send via iMessage") { NSSharingService(named: .composeMessage)?.perform(withItems: [file]) }
    Button("AirDrop") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [file]) }
    Divider()
    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    Divider()
    Button("Hide from Sailfish", action: hide)
  }
}
