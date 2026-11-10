import MacCleanerCore
import SwiftUI

/// The top of every screen: the title, the Scan button (Try again only after a failed scan, not after a
/// failed action), progress while the job is busy, Cancel only while a scan can be cancelled, and the
/// failure message.
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
            if let failure = job.failureText {
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

extension JobModel {
    /// The `.failed` message for display, nil otherwise. A missing script or demo fixture (`not_found`,
    /// whose message is only a path or fixture name) is labelled as such. `cancelled` (the user dismissed
    /// the password dialog) is not an error: it has no message here, and the screen says so neutrally.
    var failureText: String? {
        guard case .failed(let message) = phase, !hasFailure("cancelled") else { return nil }
        return failures.last?.code == "not_found" ? L("Tidak ditemukan: ", "Not found: ") + message : message
    }
}
