import MacCleanerCore
import SwiftUI

enum DockerTab: Hashable { case containers, images, volumes }

/// Docker: the engine's state, and while it runs a summary, the containers/images/volumes to remove and the
/// prune actions. `job` holds the status (`docker-status`) and runs every action; the lists load into
/// `appState.dockerList`. After an action the status is read again, which rebuilds the running view and so
/// reloads the current list (see `DockerRunningView`).
struct DockerView: View {
    @ObservedObject var job: JobModel
    @EnvironmentObject private var appState: AppState
    // Held here, not in the running view: that view is rebuilt after every status read.
    @ViewState private var tab: DockerTab = .containers
    @ViewState private var showAllAtOnce = false

    /// What `docker-status` (or a `docker_missing` / `docker_not_ready` answer) says about the engine.
    private var mode: DockerMode? { DockerMode(meta: job.meta, failureCodes: job.failures.map(\.code)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScanBar(job: job, title: Screen.docker.title, scanLabel: L("Muat ulang", "Refresh"), onScan: { await status() })
            content
            if job.freedKB != nil { ResultBanner(job: job) }
            if !job.log.isEmpty { LogPanel(job: job) }
        }
        .padding(20)
        // A log from an earlier action stays; a status read adds no lines of its own.
        .task { await status(keepLog: job.phase != .idle) }
    }

    @ViewBuilder private var content: some View {
        switch job.screenContent {
        case .scanning:
            EmptyState(symbol: Screen.docker.symbol, text: L("Memeriksa Docker…", "Checking Docker…"))
        case .failed:
            Spacer(minLength: 0)  // ScanBar shows the message and Try again
        case .idle, .empty, .list:
            // Only a running engine has df rows (R16), so a stopped one is `.empty` or, during docker-start, `.idle`.
            if let mode {
                modeContent(mode)
            } else {
                EmptyState(symbol: Screen.docker.symbol, text: L("Tekan Muat ulang untuk memeriksa Docker.", "Press Refresh to check Docker."))
            }
        }
    }

    @ViewBuilder private func modeContent(_ mode: DockerMode) -> some View {
        switch mode {
        case .missing:
            EmptyState(symbol: Screen.docker.symbol, text: L("Docker tidak terpasang di Mac ini.", "Docker isn't installed on this Mac."))
        case .stoppedOrbStack:
            ModeMessage(text: L("OrbStack belum berjalan.", "OrbStack isn't running."),
                        buttonTitle: L("Jalankan OrbStack", "Start OrbStack"), note: startNote, isBusy: job.isBusy, action: start)
        case .stoppedDesktop:
            ModeMessage(text: L("Docker Desktop belum berjalan.", "Docker Desktop isn't running."),
                        buttonTitle: L("Buka Docker Desktop", "Open Docker Desktop"), note: startNote, isBusy: job.isBusy, action: start)
        case .notReady:
            ModeMessage(text: L("Docker belum siap.", "Docker is not ready."),
                        buttonTitle: L("Coba lagi", "Try again"), note: nil, isBusy: job.isBusy, action: { await status() })
        case .running:
            DockerRunningView(job: job, list: appState.dockerList, tab: $tab, showAllAtOnce: $showAllAtOnce,
                              afterAction: afterAction)
        }
    }

    /// Starting is not a deletion, so a dry run does not stop it (the engine starts it for real, like the CLI).
    private var startNote: String? {
        appState.dryRun ? L("Mode coba tidak menahan ini: Docker tetap dijalankan.", "Dry run does not hold this back: Docker is really started.") : nil
    }

    private func status(keepLog: Bool = false) async {
        await job.scan(["docker-status"], keepLog: keepLog)
    }

    private func start() async {
        await job.run(["docker-start"])
        await status(keepLog: true)
    }

    /// After every action: the disk bar, then the status again (the running view then reloads the list).
    private func afterAction() async {
        await appState.refreshDisk()
        await status(keepLog: true)
    }
}

/// A message about the engine with the one button that moves on from it.
private struct ModeMessage: View {
    let text: String
    let buttonTitle: String
    let note: String?
    let isBusy: Bool
    let action: () async -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: Screen.docker.symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
            Button(buttonTitle) { Task { await action() } }
                .disabled(isBusy)
            if let note { Text(note).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
