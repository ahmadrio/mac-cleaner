import MacCleanerCore
import SwiftUI

/// Rarely used apps: every app unopened for more than N days (and the 10 largest), with a way to uninstall one.
struct AppsView: View {
    @ObservedObject var job: JobModel
    @EnvironmentObject private var appState: AppState
    @ViewState private var daysText = String(ScanDays.defaultDays)
    /// The days of the scan on screen (the field may have been edited since).
    @ViewState private var scannedDays = ScanDays.defaultDays
    @ViewState private var selection: Set<AppUsage.ID> = []
    @ViewState private var target: UninstallTarget?

    private var apps: [AppUsage] { job.rows("app", as: AppUsage.init(fields:)) }
    private var days: Int? { ScanDays.parse(daysText) }

    var body: some View {
        let apps = apps
        VStack(alignment: .leading, spacing: 12) {
            ScanBar(job: job, title: Screen.apps.title, scanLabel: L("Pindai", "Scan"), onScan: scan)
            daysField
            content(apps)
        }
        .padding(20)
        .sheet(item: $target) { target in
            UninstallSheet(appPath: target.path, onFinished: { Task { await rescan() } })
        }
    }

    private var daysField: some View {
        HStack(spacing: 6) {
            Text(L("Anggap jarang dipakai kalau tidak dibuka lebih dari", "Treat as rarely used if unopened for more than"))
            TextField("", text: $daysText)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .onSubmit { Task { await scan() } }
                .disabled(job.isBusy)
                .accessibilityLabel(L("Jumlah hari", "Number of days"))
            Text(L("hari", "days"))
            if days == nil {
                Text(L("Masukkan angka (maksimal 6 digit).", "Enter a number (up to 6 digits)."))
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
    }

    @ViewBuilder private func content(_ apps: [AppUsage]) -> some View {
        switch job.screenContent {
        case .scanning:
            EmptyState(symbol: Screen.apps.symbol,
                       text: L("Memindai aplikasi… (ukuran + kapan terakhir dibuka)", "Scanning apps… (size + last opened)"))
        case .empty:
            EmptyState(symbol: "checkmark.circle",
                       text: L("Tidak ada aplikasi ditemukan di /Applications.", "No apps found in /Applications."))
        case .idle:
            EmptyState(symbol: Screen.apps.symbol,
                       text: L("Tekan Pindai untuk mencari aplikasi yang jarang dipakai.", "Press Scan to find rarely used apps."))
        case .failed:
            Spacer(minLength: 0)  // ScanBar shows the message and Try again
        case .list:
            list(apps)
        }
    }

    private func list(_ apps: [AppUsage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Aplikasi jarang dipakai (> \(scannedDays) hari) + 10 terbesar, urut dari yang terbesar:",
                   "Rarely used apps (> \(scannedDays) days) + 10 largest, largest first:"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Table(apps, selection: $selection) {
                TableColumn(L("Ukuran", "Size")) { app in
                    Text(ByteFormat.string(kb: app.kb)).monospacedDigit()
                }
                .width(min: 70, ideal: 80)
                TableColumn("Status") { app in
                    Text(app.isRare ? L("jarang", "rare") : L("aktif", "active"))
                        .foregroundStyle(app.isRare ? Color.orange : Color.secondary)
                }
                .width(min: 60, ideal: 70)
                TableColumn(L("Terakhir dibuka", "Last opened")) { app in
                    Text(lastOpened(app.lastOpened))
                }
                .width(min: 110, ideal: 130)
                TableColumn(L("Nama", "Name"), value: \.name)
            }
            summary
            HStack {
                Spacer()
                Button(L("Uninstall…", "Uninstall…")) {
                    if selection.count == 1, let path = selection.first { target = UninstallTarget(path: path) }
                }
                .disabled(selection.count != 1 || job.isBusy)
            }
        }
    }

    @ViewBuilder private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let s = AppsSummary(meta: job.meta) {
                Text(L("\(s.rareCount) aplikasi jarang dipakai, total \(ByteFormat.string(kb: s.rareKB)).",
                       "\(s.rareCount) rarely used apps, \(ByteFormat.string(kb: s.rareKB)) in total."))
                    .fontWeight(.semibold)
            }
            Text(L("'tidak tercatat' = macOS tidak punya catatan kapan aplikasi dibuka (belum pernah dibuka, atau hanya dibuka lewat CLI).",
                   "'never recorded' = macOS has no record of the app being opened (never opened, or only launched from the CLI)."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func lastOpened(_ when: LastOpened) -> String {
        switch when {
        case .never: L("tidak tercatat", "never recorded")
        case .today: L("hari ini", "today")
        case .daysAgo(let n): "\(n) " + L("hari lalu", "days ago")
        }
    }

    private func scan() async {
        guard let days else { return }  // the field says what is wrong
        selection = []
        scannedDays = days
        await job.scan(["apps-scan", String(days)])
    }

    /// After an uninstall: the scan again with the days it was run with.
    private func rescan() async {
        selection = []
        await job.scan(["apps-scan", String(scannedDays)])
    }
}
