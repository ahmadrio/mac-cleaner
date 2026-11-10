import MacCleanerCore
import SwiftUI

/// Clean caches: scan, tick what to clean (or use the two presets), confirm, clean.
struct CacheView: View {
    @ObservedObject var job: JobModel
    @EnvironmentObject private var appState: AppState
    @ViewState private var selected: Set<String> = []
    @ViewState private var confirming = false

    private var items: [CacheItem] { job.rows("cache", as: CacheItem.init(fields:)) }

    var body: some View {
        let items = items
        VStack(alignment: .leading, spacing: 12) {
            ScanBar(job: job, title: Screen.cache.title, scanLabel: L("Pindai", "Scan"), onScan: scan)
            if job.actionHasFailure("finder_denied") {
                PermissionCallout(kind: .automation,
                                  message: L("Izinkan Mac Cleaner mengendalikan Finder supaya bisa mengosongkan Trash.",
                                             "Allow Mac Cleaner to control Finder so it can empty the Trash."))
            }
            content(items)
            ResultBanner(job: job)
            // Only an action's log: the scan's own "Measuring caches…" line would push the table down.
            if job.showsLog { LogPanel(job: job, maxLines: 500) }
        }
        .padding(20)
    }

    @ViewBuilder private func content(_ items: [CacheItem]) -> some View {
        switch job.screenContent {
        case .scanning:
            EmptyState(symbol: Screen.cache.symbol,
                       text: L("Menghitung ukuran cache… (bisa 10–60 detik)", "Measuring caches… (may take 10–60 seconds)"))
        case .empty:
            EmptyState(symbol: "checkmark.circle",
                       text: L("Tidak ada cache berarti yang perlu dibersihkan.", "No significant caches to clean."))
        case .idle:
            EmptyState(symbol: Screen.cache.symbol,
                       text: L("Tekan Pindai untuk menghitung ukuran cache.", "Press Scan to measure the caches."))
        case .failed:
            Spacer(minLength: 0)  // ScanBar shows the message and Try again
        case .list:
            list(items)
        }
    }

    private func list(_ items: [CacheItem]) -> some View {
        let chosen = items.filter { selected.contains($0.id) }
        let size = CacheItem.totalKB(items, selected: selected)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(L("Pilih semua yang aman", "Select all safe")) {
                    selected = CacheItem.select(items, preset: .safe)
                }
                Button(L("Aman + berat", "Safe + heavy")) {
                    selected = CacheItem.select(items, preset: .safeAndHeavy)
                }
                Spacer()
                if let totals { Text(totals).foregroundStyle(.secondary).monospacedDigit() }
            }
            .disabled(job.isBusy)

            table(items)

            VStack(alignment: .leading, spacing: 4) {
                Text(L("aman = dibuat ulang otomatis · berat = di-download ulang saat build berikutnya",
                       "safe = rebuilt automatically · heavy = re-downloaded on the next build"))
                Text(L("permanen = tidak bisa dikembalikan", "permanent = cannot be undone"))
                Label {
                    Text(quitWarning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(size > 0 ? L("Bersihkan", "Clean") + " " + ByteFormat.string(kb: size) : L("Bersihkan", "Clean")) {
                    confirming = true
                }
                .disabled(chosen.isEmpty || job.isBusy)
            }
        }
        .sheet(isPresented: $confirming) { confirmSheet(chosen) }
    }

    private func table(_ items: [CacheItem]) -> some View {
        Table(items) {
            TableColumn("") { item in
                Toggle(item.label, isOn: binding(item.id)).labelsHidden().disabled(job.isBusy)
            }
            .width(24)
            TableColumn(L("Ukuran", "Size")) { item in
                Text(ByteFormat.string(kb: item.kb))
                    .monospacedDigit()
                    .help(item.kb < 0 ? L("Ukuran Trash tidak bisa dihitung.", "The size of the Trash can't be measured.") : "")
            }
            .width(min: 70, ideal: 80)
            TableColumn("Item", value: \.label)
            TableColumn(L("Jenis", "Type")) { item in KindBadge(kind: item.kind) }
                .width(min: 80, ideal: 90)
        }
    }

    private func confirmSheet(_ chosen: [CacheItem]) -> some View {
        let dry = appState.dryRun
        let permanent = chosen.contains { $0.kind == .permanent }
        let warning = permanent
            ? quitWarning + " " + L("Isi Trash dihapus permanen.", "The Trash is emptied permanently.")
            : quitWarning
        return ConfirmSheet(
            title: L("Bersihkan cache yang dipilih?", "Clean the selected caches?")
                + (dry ? L(" (mode coba: tidak ada yang dihapus)", " (dry run: nothing is deleted)") : ""),
            items: chosen.map { "\($0.label) · \(ByteFormat.string(kb: $0.kb))" },
            warning: warning,
            typedWord: nil,
            confirmLabel: L("Bersihkan", "Clean"),
            onConfirm: { await clean(chosen.map(\.id)) })
    }

    private var quitWarning: String {
        L("Tutup IDE, browser & aplikasi lain dulu supaya cache-nya terhapus bersih.",
          "Quit your IDE, browser and other apps first so their caches clear completely.")
    }

    /// "Total aman: 20.1 GB · berat: 4.8 GB" from the scan's meta.
    private var totals: String? {
        guard let safe = job.meta["total_safe"].flatMap({ Int($0) }),
              let heavy = job.meta["total_heavy"].flatMap({ Int($0) }) else { return nil }
        return L("Total aman", "Total safe") + ": " + ByteFormat.string(kb: safe)
            + " · " + L("berat", "heavy") + ": " + ByteFormat.string(kb: heavy)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }

    private func scan() async {
        selected = []
        await job.scan(["caches-scan"])
    }

    /// Cleans, then refreshes the disk bar. A real clean that went through is followed by a rescan (sizes changed),
    /// which keeps the clean's log and result. A dry run changed nothing; a failed clean keeps its error (finder_denied).
    private func clean(_ ids: [String]) async {
        await job.run(["caches-clean"] + ids)
        await appState.refreshDisk()
        if job.phase == .done, !job.lastRunWasDryRun {
            selected = []
            await job.scan(["caches-scan"], keepLog: true)
        }
    }
}
