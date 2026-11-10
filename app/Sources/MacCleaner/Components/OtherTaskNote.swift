import MacCleanerCore
import SwiftUI

/// Says why a screen's action buttons are off: another screen runs an action, and only one runs at a time (two
/// Homebrew runs, say, would fight over its lock). Scans may still run. Shows nothing otherwise.
struct OtherTaskNote: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var job: JobModel

    var body: some View {
        if appState.anyRunning, job.phase != .running {
            Label(L("Tugas lain sedang berjalan — tunggu sampai selesai.", "Another task is running — wait until it finishes."),
                  systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
