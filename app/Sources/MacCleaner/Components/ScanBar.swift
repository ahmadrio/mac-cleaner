import MacCleanerCore
import SwiftUI

/// The top of every screen: the title, the Scan button (Try again only after a failed scan, not after a
/// failed action), progress while the job is busy, Cancel only while a scan can be cancelled, and the
/// failure message of a failed scan. A failed action is the screen's result banner's to tell (`ResultBanner`,
/// or the screen's own), because it must outlive the rescan that follows the action.
struct ScanBar: View {
    @ObservedObject var job: JobModel
    let title: String
    let scanLabel: String
    let onScan: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                if job.canCancel {
                    Button(L("Batal", "Cancel")) { job.cancel() }
                }
                Button(job.scanFailed ? L("Coba lagi", "Try again") : scanLabel) {
                    Task { await onScan() }
                }
                .disabled(job.isBusy)
            }
            if job.isBusy { progress }
            if job.scanFailed, let failure = job.failureText {
                Label {
                    Text(failure).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
        }
    }

    private var progress: some View {
        let step = job.progress?.step, total = job.progress?.total
        return VStack(alignment: .leading, spacing: 4) {
            if let step, let total, total > 0 {
                ProgressView(value: Double(min(step, total)), total: Double(total))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(job.progress?.text ?? L("Sedang berjalan…", "Working…"))
                Spacer()
                if let step, let total { Text(verbatim: "\(step)/\(total)").monospacedDigit() }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension FailureNote {
    /// The failure for display. A job that failed without an error record points at the log.
    @MainActor var text: String {
        switch self {
        case .message(let message): message
        case .notFound(let name): L("Tidak ditemukan: ", "Not found: ") + name
        case .notAllowed(let path): L("Tidak diizinkan: ", "Not allowed: ") + path
        case .seeLog: L("Ada langkah yang gagal — lihat detail di bawah.", "Something didn't work — see the details below.")
        }
    }
}

extension JobModel {
    /// The `.failed` message for display, nil otherwise. Never a bare "exit 1": a failure without an error record
    /// points at the log. `finder_denied` has no text (the screen's Automation callout explains it), nor has
    /// `cancelled` (the user dismissed the password dialog, which is not an error).
    var failureText: String? { failureNote?.text }
}
