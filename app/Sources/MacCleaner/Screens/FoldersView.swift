import AppKit
import MacCleanerCore
import SwiftUI

/// Largest folders: a read-only list of where the space goes, with a way to reveal each folder in Finder.
struct FoldersView: View {
    @ObservedObject var job: JobModel
    @ViewState private var selection: Set<DirUsage.ID> = []

    /// The demo fixtures use /Users/demo paths.
    private static let home = EngineLocator.isDemo ? "/Users/demo" : NSHomeDirectory()

    private var dirs: [DirUsage] { job.rows("dir", as: DirUsage.init(fields:)) }

    var body: some View {
        let dirs = dirs
        ScreenScaffold {
            ScanBar(job: job, title: Screen.folders.title, scanLabel: L("Pindai", "Scan"), onScan: scan)
            if job.screenContent != .scanning, job.meta["fda"] == "0" {
                PermissionCallout(kind: .fullDiskAccess,
                                  message: L("Beri Mac Cleaner akses Full Disk Access supaya ~/Library/Containers ikut dihitung.",
                                             "Give Mac Cleaner Full Disk Access to include ~/Library/Containers."))
            }
        } content: {
            content(dirs)
        }
    }

    @ViewBuilder private func content(_ dirs: [DirUsage]) -> some View {
        switch job.screenContent {
        case .scanning:
            EmptyState(symbol: Screen.folders.symbol,
                       text: L("Mengukur folder & data aplikasi terbesar… (bisa 1–3 menit)",
                               "Measuring the largest folders & app data… (may take 1–3 minutes)"))
        case .empty:
            EmptyState(symbol: "checkmark.circle",
                       text: L("Tidak ada folder besar yang ditemukan.", "No large folders found."))
        case .idle:
            EmptyState(symbol: Screen.folders.symbol,
                       text: L("Tekan Pindai untuk mencari folder terbesar.", "Press Scan to find the largest folders."))
        case .failed:
            // ScanBar shows the message and Try again; a failure without a message points at these lines
            if job.showsLog { LogPanel(job: job, maxLines: 50) } else { Spacer(minLength: 0) }
        case .list:
            list(dirs)
        }
    }

    private func list(_ dirs: [DirUsage]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(dirs, selection: $selection) {
                TableColumn(L("Ukuran", "Size")) { dir in
                    Text(ByteFormat.string(kb: dir.kb)).monospacedDigit()
                }
                .width(min: 70, ideal: 80)
                TableColumn(L("Lokasi", "Location")) { dir in
                    HStack {
                        Text(PathFormat.tilde(dir.path, home: Self.home))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(dir.path)
                        Spacer(minLength: 8)
                        Button(L("Tampilkan di Finder", "Show in Finder")) { reveal(dir.path) }
                            .buttonStyle(.link)
                    }
                }
            }
            .contextMenu(forSelectionType: DirUsage.ID.self) { paths in
                if !paths.isEmpty {
                    Button(L("Tampilkan di Finder", "Show in Finder")) { paths.forEach(reveal) }
                }
            } primaryAction: { paths in
                paths.forEach(reveal)  // double-click
            }
            .screenTable()
            Text(L("Desktop, Documents, Downloads, Pictures, Music & Movies tidak dihitung (butuh izin macOS).",
                   "Desktop, Documents, Downloads, Pictures, Music & Movies are skipped (they need macOS permission)."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func scan() async {
        selection = []
        await job.scan(["bigdata-scan"])
    }
}
