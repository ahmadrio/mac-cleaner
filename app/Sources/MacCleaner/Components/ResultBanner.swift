import MacCleanerCore
import SwiftUI

/// The result of the job's last action that reported freed space (`@@freed`); nothing before that.
/// It stays through the rescan that follows the action.
struct ResultBanner: View {
    @ObservedObject var job: JobModel

    var body: some View {
        if let freed = job.freedKB {
            let color: Color = job.lastRunWasDryRun ? .blue : .green
            Label {
                Text(message(freed))
            } icon: {
                Image(systemName: job.lastRunWasDryRun ? "info.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(color)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// The CLI's `report_freed` texts.
    private func message(_ freed: Int) -> String {
        if job.lastRunWasDryRun { return L("Mode coba: tidak ada yang dihapus.", "Dry run: nothing was deleted.") }
        guard freed > 0 else {
            return L("Selesai. macOS kadang butuh beberapa menit untuk memperbarui angka ruang kosong.",
                     "Done. macOS can take a few minutes to update the free-space number.")
        }
        let size = ByteFormat.string(kb: freed)
        guard let disk = job.disk else { return L("Ruang kosong bertambah \(size).", "Freed \(size).") }
        let free = ByteFormat.string(kb: disk.freeKB)
        return L("Ruang kosong bertambah \(size) (sekarang \(free) kosong).", "Freed \(size) (now \(free) free).")
    }
}
