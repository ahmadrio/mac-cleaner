import MacCleanerCore
import SwiftUI

/// The result of the job's last action (`JobModel.actionResult`): freed space, a dry run, a cancelled password dialog,
/// or a failure, never a success when a step failed. It stays through the rescan that follows the action and shows
/// nothing before an action or for one that reported nothing.
struct ResultBanner: View {
    @ObservedObject var job: JobModel

    var body: some View {
        if let result = job.actionResult {
            let (text, symbol, color) = describe(result)
            Label {
                Text(text)
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func describe(_ result: ActionResult) -> (String, String, Color) {
        switch result {
        case .dryRun:
            (L("Mode coba: tidak ada yang dihapus.", "Dry run: nothing was deleted."), "info.circle.fill", .blue)
        case .freed(let kb, let freeKB):
            (freedText(kb, freeKB: freeKB), "checkmark.circle.fill", .green)
        case .cancelled:
            (L("Dibatalkan.", "Cancelled."), "xmark.circle.fill", .secondary)
        case .failed(let note, let freedKB):
            (failedText(note, freedKB: freedKB), "exclamationmark.triangle.fill", .orange)
        }
    }

    /// The CLI's `report_freed` texts.
    private func freedText(_ freed: Int, freeKB: Int?) -> String {
        guard freed > 0 else {
            return L("Selesai. macOS kadang butuh beberapa menit untuk memperbarui angka ruang kosong.",
                     "Done. macOS can take a few minutes to update the free-space number.")
        }
        let size = ByteFormat.string(kb: freed)
        guard let freeKB else { return L("Ruang kosong bertambah \(size).", "Freed \(size).") }
        let free = ByteFormat.string(kb: freeKB)
        return L("Ruang kosong bertambah \(size) (sekarang \(free) kosong).", "Freed \(size) (now \(free) free).")
    }

    /// The failure (the engine's message, or a pointer to the log), then what was freed anyway.
    private func failedText(_ note: FailureNote?, freedKB: Int?) -> String {
        var text = (note ?? .seeLog).text
        if let freedKB {
            let size = ByteFormat.string(kb: freedKB)
            text += " " + L("Ruang kosong tetap bertambah \(size).", "\(size) was freed anyway.")
        }
        return text
    }
}
