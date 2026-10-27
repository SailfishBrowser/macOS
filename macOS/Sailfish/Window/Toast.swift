import SwiftUI

// The toast: a dark pill at the bottom of the window with a message and, often, an action such as Undo. One
// shows at a time; a new one replaces it, and it goes after a few seconds or when closed.
struct Toast: Equatable, Identifiable {
  enum Action: Equatable {
    case undo
    // "New Tab Created": a click shows the tab opened behind the page while the sidebar was hidden.
    case goToTab(Tab.ID)
    // Full screen's "⎋ again to exit fullscreen": a link to the Shortcuts pane.
    case editShortcut
    // Tidy Downloads' Undo: the download takes back its original name.
    case revertDownloadName(Download.ID)
  }

  // The dark pill at the bottom, or the accent pill at the page's top right.
  enum Placement: Equatable {
    case bottom
    case topTrailing
    // The "Download renamed!" card at the page's top right: the new name over the struck-out original, and Undo.
    case renamed(from: String)
    // The violet pill in the window's corner, its ⌘Z drawn as a key.
    case corner

    var isTop: Bool { self != .bottom }
  }

  let id: UUID
  var message: String
  var action: Action?
  // What a click on the message does, for clickable toasts.
  var tap: Action?
  var placement = Placement.bottom
  // The undo stack's depth when an Undo toast was shown: its entry is the top one only while that holds.
  var undoDepth: Int?

  static let duration: Duration = .seconds(4)
}

struct ToastView: View {
  let toast: Toast
  let perform: (Toast.Action) -> Void
  let close: () -> Void
  @State private var isHovering = false

  var body: some View {
    if case let .renamed(original) = toast.placement {
      renamed(from: original)
    } else if toast.placement == .corner {
      corner
    } else if toast.placement == .topTrailing {
      // The top-right pill: the accent's tint, dark bold text, the whole pill the button.
      Button { toast.tap.map(perform) } label: {
        Text(toast.message).font(.system(size: 13, weight: .semibold)).lineLimit(1)
          .foregroundStyle(Theme.accentInk)
          .padding(.horizontal, 14).frame(height: 40)
          .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(isHovering ? 0.6 : 0.3)))
          .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { isHovering = $0 }
    } else {
      pill
    }
  }

  private func renamed(from original: String) -> some View {
    VStack(alignment: .trailing, spacing: 6) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Download renamed!").font(.system(size: 11, weight: .medium)).opacity(0.6)
        Text(toast.message).font(.system(size: 13, weight: .semibold))
        Text(original).font(.system(size: 11)).strikethrough().opacity(0.5)
      }
      .lineLimit(1)
      .padding(.horizontal, 12).padding(.vertical, 8)
      .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.3)))
      .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
      if let action = toast.action {
        Button { perform(action) } label: {
          Label("Undo", systemImage: "arrow.uturn.backward").labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).frame(height: 20)
            .background(Theme.accentTint, in: Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .foregroundStyle(Theme.accentInk)
  }

  // Shot 41: 257 x 47 pt, white 14 pt medium text, a 37 x 27 pt key 7 pt from the words, violet from #2A1454 to
  // #20103F on the default dark theme.
  private var corner: some View {
    let parts = toast.message.components(separatedBy: "⌘Z").map { $0.trimmingCharacters(in: .whitespaces) }
    return HStack(spacing: 7) {
      Text(parts[0])
      if parts.count > 1 {
        Text("⌘Z").font(.system(size: 13, weight: .bold))
          .frame(width: 37, height: 27)
          .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        Text(parts[1])
      }
    }
    .font(.system(size: 14, weight: .medium))
    .foregroundStyle(.white)
    .lineLimit(1)
    .padding(.leading, 13)
    .padding(.trailing, 12)
    .frame(height: 47)
    .background(
      LinearGradient(colors: [Color(hex: 0x2A1454), Color(hex: 0x20103F)], startPoint: .top, endPoint: .bottom),
      in: RoundedRectangle(cornerRadius: 8))
  }

  private var pill: some View {
    HStack(spacing: 10) {
      if let tap = toast.tap {
        Button { perform(tap) } label: { Text(toast.message).lineLimit(1).contentShape(Rectangle()) }
          .buttonStyle(.plain)
      } else {
        Text(toast.message).lineLimit(1)
      }
      if let action = toast.action {
        Button(action: { perform(action) }) {
          Text(title(action)).font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 8).frame(height: 24)
            .background(action == .undo ? .white.opacity(0.14) : Theme.accent, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
      }
      Button(action: close) {
        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.white.opacity(0.6))
    }
    .font(.system(size: 13, weight: .semibold))
    .foregroundStyle(.white)
    .padding(.leading, 14)
    .padding(.trailing, 8)
    .frame(height: 40)
    .background(Theme.menu.opacity(isHovering ? 1 : 0.92), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(isHovering ? 0.14 : 0.08)))
    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    .onHover { isHovering = $0 }
  }

  private func title(_ action: Toast.Action) -> String {
    switch action {
    case .undo: "Undo"
    case .goToTab: "Go there"
    case .editShortcut: "Edit the shortcut ↗"
    case .revertDownloadName: "Undo"
    }
  }
}
