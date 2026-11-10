import SwiftUI

/// Explains a missing macOS permission, with a button that opens the right System Settings panel.
struct PermissionCallout: View {
    let kind: PermissionKind
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(kind.title).font(.headline)
                Text(message)
                Text(L("Setelah Mac Cleaner diperbarui, izin ini mungkin perlu diberikan lagi.",
                       "After Mac Cleaner is updated, you may need to grant this again."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L("Buka Pengaturan Sistem", "Open System Settings")) {
                    NSWorkspace.shared.open(kind.settingsURL)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
