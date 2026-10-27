import SwiftUI

// A backup with what it holds, for Help > Restore Data.
struct BackupEntry: Identifiable {
  let backup: Backup
  let snapshot: Snapshot

  var id: URL { backup.id }
  var spaceCount: Int { snapshot.windows.flatMap(\.spaces.spaces).count }
  var tabCount: Int { snapshot.windows.flatMap(\.spaces.spaces).flatMap(\.tabs).count }
}

// Restore Data: the sidebar backups, newest first; the chosen one takes the sidebar's place.
struct RestoreDataDialog: View {
  let entries: [BackupEntry]
  let restore: (Snapshot) -> Void
  let dismiss: () -> Void
  @State private var chosen: BackupEntry.ID?

  var body: some View {
    ConfirmModal(
      confirm: "Restore", isValid: chosen != nil,
      onConfirm: {
        guard let entry = entries.first(where: { $0.id == chosen }) else { return }
        restore(entry.snapshot)
        dismiss()
      },
      onCancel: dismiss
    ) {
      Text("Restore Data").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
      Text("Sidebar backups on this computer. The sidebar as it is now is kept as a backup too.")
        .font(.system(size: 14)).padding(.top, 8)
      if entries.isEmpty {
        Text("No backups yet").font(.system(size: 14)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 80)
          .background(Color(hex: 0x262B3D), in: RoundedRectangle(cornerRadius: 6))
          .padding(.top, 16)
      } else {
        ScrollView {
          VStack(spacing: 2) {
            ForEach(entries) { entry in
              HStack {
                Text(entry.backup.date, format: .dateTime.weekday(.wide).month().day().hour().minute())
                  .font(.system(size: 14))
                Spacer()
                Text("\(entry.spaceCount) \(entry.spaceCount == 1 ? "space" : "spaces"), \(entry.tabCount) \(entry.tabCount == 1 ? "tab" : "tabs")")
                  .font(.system(size: 12)).foregroundStyle(.secondary)
              }
              .padding(.horizontal, 10)
              .frame(height: 34)
              .background(chosen == entry.id ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 6))
              .contentShape(Rectangle())
              .onTapGesture { chosen = entry.id }
            }
          }
        }
        .frame(maxHeight: 240)
        .padding(4)
        .background(Color(hex: 0x262B3D), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
        .padding(.top, 16)
      }
    }
    .frame(width: 450)
  }
}
