import AppKit
import ComposableArchitecture
import SwiftUI

extension SharedKey where Self == AppStorageKey<AppIcon>.Default {
  static var appIcon: Self { Self[.appStorage(AppIcon.defaultsKey), default: .original] }
}

// Shows the chosen icon in the Dock (the bundle's own for the original) and has the Dock tile plug-in redraw.
@MainActor
func applyAppIcon() {
  @Shared(.appIcon) var icon
  NSApp.applicationIconImage = icon == .original ? nil : icon.image()
  DistributedNotificationCenter.default().postNotificationName(
    .init(Bundle.main.bundleIdentifier! + "." + AppIcon.defaultsKey), object: nil, deliverImmediately: true)
}

struct IconPane: View {
  @Shared(.appIcon) private var current

  var body: some View {
    // Nine icons are taller than the pane, so the list scrolls.
    ScrollView {
      VStack(spacing: 0) {
        ForEach(AppIcon.allCases, id: \.self) { icon in
          HStack(spacing: 0) {
            Circle()
              .strokeBorder(.white.opacity(current == icon ? 0 : 0.5))
              .background(Circle().fill(current == icon ? Color.accentColor : .white.opacity(0.9)))
              .overlay(Circle().fill(.white).padding(7).opacity(current == icon ? 1 : 0))
              .frame(width: 22, height: 22)
              .padding(.trailing, 21)
            Image(nsImage: icon.image()).resizable().frame(width: 62, height: 62).padding(.trailing, 8)
            VStack(alignment: .leading, spacing: 3) {
              Text(icon.name).font(.system(size: 15, weight: .semibold))
              if current == icon {
                Text("CURRENT ICON").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
              }
            }
            Spacer()
          }
          .frame(height: 81)
          .contentShape(Rectangle())
          .onTapGesture {
            $current.withLock { $0 = icon }
            applyAppIcon()
          }
          if icon != AppIcon.allCases.last {
            Divider().padding(.horizontal, 24)
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 9)
      .padding(.bottom, 20)
      .settingsCard()
      .padding(.vertical, 20)
      .padding(.horizontal, 64)
    }
  }
}
