import MacCleanerCore
import SwiftUI

/// RAM: how much is used and the memory pressure, the heaviest apps (tick some to quit them), the heaviest
/// other processes (info only) and a purge of the cached files.
struct RAMView: View {
    @ObservedObject var job: JobModel
    @EnvironmentObject private var appState: AppState
    @ViewState private var selected: Set<String> = []
    @ViewState private var confirmingQuit = false
    @ViewState private var confirmingPurge = false

    private var apps: [MemApp] { job.rows("memapp", as: MemApp.init(fields:)) }
    private var procs: [MemProc] { job.rows("memproc", as: MemProc.init(fields:)) }
    private var summary: MemSummary? { MemSummary(meta: job.meta) }
    /// "RAM used: 12.4 GB → 9.0 GB" after a quit or purge that went through. Kept in the job (the rescan after the
    /// action replaces its meta), so it survives switching screens or languages.
    private var outcome: RAMOutcome? { job.outcome as? RAMOutcome }

    var body: some View {
        let apps = apps
        let chosen = apps.filter { $0.isSelectable && selected.contains($0.id) }
        ScreenScaffold {
            ScanBar(job: job, title: Screen.ram.title, scanLabel: L("Pindai", "Scan"), onScan: scan)
        } content: {
            content(apps, chosen: chosen)
        } footer: {
            if let outcome { OutcomeBanner(text: text(outcome)) }
            ResultBanner(job: job)  // a purge that failed, or whose password dialog was dismissed
            if job.showsLog, !job.actionHasFailure("cancelled") { LogPanel(job: job) }
        }
    }

    @ViewBuilder private func content(_ apps: [MemApp], chosen: [MemApp]) -> some View {
        switch job.screenContent {
        case .scanning:
            EmptyState(symbol: Screen.ram.symbol, text: L("Membaca pemakaian RAM…", "Reading RAM usage…"))
        case .empty:
            VStack(alignment: .leading, spacing: 12) {
                summaryView
                EmptyState(symbol: "checkmark.circle", text: L("Tidak ada aplikasi yang memakai banyak RAM.", "No apps are using much RAM."))
            }
        case .idle:
            EmptyState(symbol: Screen.ram.symbol, text: L("Tekan Pindai untuk melihat pemakaian RAM.", "Press Scan to see RAM usage."))
        case .failed:
            Spacer(minLength: 0)  // ScanBar shows the message and Try again
        case .list:
            VStack(alignment: .leading, spacing: 12) {
                summaryView
                table(apps)
                processesView
                actions(chosen)
            }
            .sheet(isPresented: $confirmingQuit) { quitSheet(chosen) }
            .sheet(isPresented: $confirmingPurge) { purgeSheet }
        }
    }

    // MARK: summary

    @ViewBuilder private var summaryView: some View {
        if let s = summary {
            let color = pressureColor(s.pressure)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("RAM: \(Text(ByteFormat.string(kb: s.used)).bold()) \(L("terpakai dari", "used of")) \(ByteFormat.string(kb: s.total)) (\(s.usedPercent)%)")
                    Text(verbatim: "·")
                    Text(L("Tekanan memori:", "Memory pressure:"))
                    Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
                    Text(pressureName(s.pressure)).foregroundStyle(color).bold()
                }
                ProgressView(value: s.usedFraction).tint(color)
                Text("\(L("Aplikasi", "Apps")) \(ByteFormat.string(kb: s.app)) · Wired \(ByteFormat.string(kb: s.wired)) · \(L("Terkompresi", "Compressed")) \(ByteFormat.string(kb: s.comp)) · \(L("Cache file", "Cached files")) \(ByteFormat.string(kb: s.cached)) · Swap \(ByteFormat.string(kb: s.swap))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("macOS sengaja memakai RAM kosong sebagai cache — yang penting tekanan memori.",
                           "macOS uses free RAM as cache on purpose — what matters is memory pressure."))
                    Text(L("Kalau oranye atau merah, tutup aplikasi yang paling berat.",
                           "If it's orange or red, quit the heaviest apps."))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func pressureColor(_ pressure: MemPressure) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }

    private func pressureName(_ pressure: MemPressure) -> String {
        switch pressure {
        case .normal: L("normal", "normal")
        case .warning: L("peringatan", "warning")
        case .critical: L("kritis", "critical")
        case .unknown: "?"
        }
    }

    // MARK: apps and processes

    private func table(_ apps: [MemApp]) -> some View {
        Table(apps) {
            TableColumn("") { app in
                if app.isSelectable {
                    Toggle(app.name, isOn: binding(app.id)).labelsHidden().disabled(job.isBusy)
                }
            }
            .width(24)
            TableColumn(L("Memori", "Memory")) { app in
                Text(ByteFormat.string(kb: app.kb)).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn(L("Aplikasi", "App")) { app in
                HStack(spacing: 6) {
                    Text(app.name)
                    if app.isHost {
                        Text("(\(L("aplikasi ini", "this app")))").foregroundStyle(.secondary)
                    } else if !app.note.isEmpty {
                        Text("(\(app.note))").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .screenTable()
    }

    private var processesView: some View {
        let procs = procs
        return VStack(alignment: .leading, spacing: 4) {
            Text(L("Proses lain (hentikan dari tempat Anda menjalankannya):", "Other processes (stop them where you started them):"))
                .font(.callout)
                .foregroundStyle(.secondary)
            if procs.isEmpty {
                Text(verbatim: "—").foregroundStyle(.secondary)
            }
            ForEach(procs) { proc in
                HStack(spacing: 10) {
                    Text(ByteFormat.string(kb: proc.kb)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    Text(proc.note.isEmpty ? proc.path : "\(proc.path) (\(proc.note))")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: actions

    private func actions(_ chosen: [MemApp]) -> some View {
        let size = chosen.reduce(0) { $0 + $1.kb }
        return HStack {
            OtherTaskNote(job: job)
            Spacer()
            Button(L("Kosongkan cache file (purge)", "Clear cached files (purge)")) { confirmingPurge = true }
                .disabled(job.isBusy || appState.anyRunning)
            Button(chosen.isEmpty ? L("Tutup aplikasi", "Quit apps")
                                  : L("Tutup aplikasi", "Quit apps") + " · " + ByteFormat.string(kb: size)) {
                confirmingQuit = true
            }
            .disabled(chosen.isEmpty || job.isBusy || appState.anyRunning)
        }
    }

    private func quitSheet(_ chosen: [MemApp]) -> some View {
        ConfirmSheet(
            title: L("Akan ditutup:", "Will quit:")
                + (appState.dryRun ? L(" (mode coba: tidak ada yang ditutup)", " (dry run: nothing is quit)") : ""),
            items: chosen.map { "\($0.name) · \(ByteFormat.string(kb: $0.kb))" },
            warning: L("Aplikasi ditutup secara normal — kalau ada pekerjaan yang belum disimpan, aplikasinya akan bertanya dulu.",
                       "Apps quit normally — if there's unsaved work, the app asks you first."),
            typedWord: nil,
            confirmLabel: L("Tutup aplikasi", "Quit apps"),
            onConfirm: { await quit(chosen) })
    }

    private var purgeSheet: some View {
        ConfirmSheet(
            title: appState.dryRun
                ? L("Jalankan purge? (mode coba: purge tidak dijalankan)", "Run purge? (dry run: purge is not run)")
                : L("Jalankan purge? (macOS akan meminta password Anda)", "Run purge? (macOS will ask for your password)"),
            items: [],
            warning: L("purge mengosongkan cache file di RAM. macOS akan mengisinya lagi saat Anda bekerja, jadi efeknya sementara dan aplikasi bisa terasa lebih lambat sebentar.",
                       "purge empties the file cache in RAM. macOS fills it again as you work, so the effect is temporary and apps may feel slower for a moment."),
            typedWord: nil,
            confirmLabel: L("Kosongkan cache file", "Clear cached files"),
            onConfirm: { await purge() })
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }

    // MARK: work

    private func scan() async {
        selected = []
        await job.scan(["ram-scan"])  // a plain scan also clears the last outcome
    }

    /// Rescans so the numbers refresh, keeping the log of the action that came before.
    private func rescan() async {
        selected = []
        await job.scan(["ram-scan"], keepLog: true)
    }

    /// Quits the apps like the CLI: a dry run only logs each `[dry-run] quit <name>`; otherwise it asks each
    /// app to quit (a simulation in demo mode, see `AppQuitter`), warns about those still running, waits
    /// 2 s, rescans and reports "RAM used: before → after".
    private func quit(_ apps: [MemApp]) async {
        let usedBefore = summary?.used
        await job.runLocal { job in
            if job.lastRunWasDryRun {
                for app in apps { job.note(.say, "[dry-run] \(L("tutup", "quit")) \(app.name)") }
                return
            }
            let quit = await AppQuitter.quit(appPaths: apps.map(\.path))
            for app in apps {
                if quit[app.path] == true {
                    job.note(.ok, "\(app.name) \(L("ditutup.", "quit."))")
                } else {
                    job.note(.warn, L("\(app.name) masih berjalan (mungkin menunggu Anda menyimpan). Paksa tutup dengan ⌥⌘⎋ kalau perlu.",
                                      "\(app.name) is still running (maybe waiting for you to save). Force quit with ⌥⌘⎋ if needed."))
                }
            }
            try? await Task.sleep(for: .seconds(2))  // let macOS release the memory before measuring
        }
        guard !job.lastRunWasDryRun else { return }
        await rescan()
        if let before = usedBefore, let after = summary?.used {
            job.outcome = RAMOutcome.ramUsed(BeforeAfter(before: before, after: after))
        }
    }

    /// Purges the file cache through the engine (it raises the macOS password dialog; dry run is the
    /// engine's). A cancelled dialog is not an error. After a real purge, the numbers are refreshed.
    private func purge() async {
        await job.run(["ram-purge"])
        guard job.phase == .done, !job.lastRunWasDryRun else { return }
        let change = BeforeAfter(meta: job.meta, before: "cached_before", after: "cached_after")
        await rescan()
        if let change { job.outcome = RAMOutcome.cachedFiles(change) }
    }

    private func text(_ outcome: RAMOutcome) -> String {
        switch outcome {
        case .ramUsed(let change): L("RAM terpakai", "RAM used") + ": " + change.text
        case .cachedFiles(let change): L("Cache file", "Cached files") + ": " + change.text
        }
    }
}

/// A result line in the style of `ResultBanner`, for results that are not freed space.
private struct OutcomeBanner: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
