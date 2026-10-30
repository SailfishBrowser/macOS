import SwiftUI

extension URL {
  // Developer mode turns on for local servers and files.
  var isDeveloperPage: Bool {
    isFileURL || ["localhost", "127.0.0.1", "::1"].contains(host() ?? "") || host()?.hasSuffix(".localhost") == true
  }

  // The host and port, or the file's name, under a developer page's tab title.
  var developerSubtitle: String {
    isFileURL ? lastPathComponent : (host() ?? "") + (port.map { ":\($0)" } ?? "")
  }
}

// The developer mode toolbar: the full URL in monospace and developer tools, in the space's accent.
struct DeveloperBar: View {
  static let height = 40.0
  let tab: Tab
  let accent: Color
  let close: (() -> Void)?
  let edit: () -> Void

  var body: some View {
    // Shot 59: buttons 28 pt apart, groups split by 20 pt dividers 22.5 pt from the buttons beside them.
    HStack(spacing: 0) {
      // Shot 59: 11 pt, 6.5 pt a character.
      Text(tab.url.absoluteString)
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .onTapGesture(perform: edit)
        .padding(.leading, 12)
      Spacer(minLength: 8)
      BarButton(systemName: "link") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tab.url.absoluteString, forType: .string)
      }
      .help("Copy URL")
      Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 20).padding(.horizontal, 8)
      if let page = Engine.shared.page(tab.id), page.hasDeveloperTools {
        BarButton(systemName: "apple.terminal") { page.showConsole() }
          .help("Console")
        BarButton(systemName: "scope") { page.inspectElement() }
          .help("Inspect Element")
      }
      if let close {
        BarButton(systemName: "xmark", action: close)
      }
    }
    .foregroundStyle(.white)
    .padding(.trailing, 6)
    .frame(height: Self.height)
    .background { DeveloperStripes().background(accent) }
  }
}

// Shot 59: the bar's 45 degree stripes, 45 pt apart across, alternately 2% lighter.
private struct DeveloperStripes: View {
  var body: some View {
    Canvas { context, size in
      var x = -size.height
      while x < size.width {
        var stripe = Path()
        stripe.move(to: CGPoint(x: x, y: 0))
        stripe.addLine(to: CGPoint(x: x + 22.5, y: 0))
        stripe.addLine(to: CGPoint(x: x + 22.5 + size.height, y: size.height))
        stripe.addLine(to: CGPoint(x: x + size.height, y: size.height))
        context.fill(stripe, with: .color(.white.opacity(0.02)))
        x += 45
      }
    }
  }
}

// Developer mode's ⌄ beside reload: reloading with or without the cache.
struct ReloadMenu: View {
  var body: some View {
    Menu {
      Button("Reload") { NSApp.sendAction(#selector(WindowController.reload(_:)), to: nil, from: nil) }
        .keyboardShortcut("r")
      Button("Refresh (Ignore Cache)") {
        NSApp.sendAction(#selector(WindowController.reloadBypassingCache(_:)), to: nil, from: nil)
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
    } label: {
      Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.icon)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .frame(width: 14, height: 28)
    .padding(.leading, -8)
  }
}
