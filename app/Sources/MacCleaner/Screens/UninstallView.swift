import MacCleanerCore
import SwiftUI

/// Uninstall apps: every app in /Applications and ~/Applications, searchable by name.
struct UninstallView: View {
    @ObservedObject var job: JobModel
    @ViewState private var query = ""
    @ViewState private var selection: Set<AppEntry.ID> = []
    @ViewState private var target: UninstallTarget?

    private var entries: [AppEntry] { job.rows("appname", as: AppEntry.init(fields:)) }

    var body: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: 12) {
            ScanBar(job: job, title: Screen.uninstall.title, scanLabel: L("Muat ulang", "Reload"), onScan: scan)
            content(entries)
        }
        .padding(20)
        .task { await scan() }  // the list is quick, and apps may have come or gone since
        .sheet(item: $target) { target in
            UninstallSheet(appPath: target.path, onFinished: { Task { await scan() } })
        }
    }

    @ViewBuilder private func content(_ entries: [AppEntry]) -> some View {
        switch job.screenContent {
        case .scanning:
            EmptyState(symbol: Screen.uninstall.symbol, text: L("Membaca daftar aplikasi…", "Reading the app list…"))
        case .empty:
            EmptyState(symbol: "checkmark.circle",
                       text: L("Tidak ada aplikasi ditemukan di /Applications.", "No apps found in /Applications."))
        case .idle:
            EmptyState(symbol: Screen.uninstall.symbol,
                       text: L("Tekan Muat ulang untuk melihat daftar aplikasi.", "Press Reload to see the app list."))
        case .failed:
            Spacer(minLength: 0)  // ScanBar shows the message and Try again
        case .list:
            list(entries)
        }
    }

    private func list(_ entries: [AppEntry]) -> some View {
        let shown = AppEntry.filter(entries, query: query)
        return VStack(alignment: .leading, spacing: 10) {
            TextField(L("Cari aplikasi (sebagian nama)", "Search apps (part of the name)"), text: $query)
                .textFieldStyle(.roundedBorder)
            if shown.isEmpty {
                EmptyState(symbol: "magnifyingglass",
                           text: L("Tidak ada aplikasi yang cocok dengan '\(query)'.", "No app matches '\(query)'."))
            } else {
                Table(shown, selection: $selection) {
                    TableColumn(L("Nama", "Name"), value: \.name)
                    TableColumn(L("Lokasi", "Location")) { entry in
                        Text(tildePath(entry.path)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(entry.path)
                    }
                }
            }
            HStack {
                Spacer()
                Button(L("Uninstall…", "Uninstall…")) {
                    if selection.count == 1, let path = selection.first { target = UninstallTarget(path: path) }
                }
                .disabled(selection.count != 1 || !shown.contains { selection.contains($0.id) } || job.isBusy)
            }
        }
    }

    private func scan() async {
        guard !job.isBusy else { return }
        selection = []
        await job.scan(["apps-list"])
    }
}
