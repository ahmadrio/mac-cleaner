import AppKit
import MacCleanerCore
import SwiftUI

/// Update apps: what Homebrew (formulae, casks, apps installed from a DMG), Sparkle apps and `mas` could update.
/// Tick rows and update them with one `updates-apply`.
///
/// What is sent is exactly the confirmed rows minus the DMG apps that were still running after the quit step
/// (`UpdateLogic`). Apply cannot be cancelled (`JobModel` forbids it), so no Cancel is shown while it runs.
struct UpdatesView: View {
    @ObservedObject var job: JobModel
    @EnvironmentObject var appState: AppState
    @ViewState var selected: Set<String> = []
    @ViewState var confirming = false
    /// DMG apps that were running when the confirmation opened: the sheet says they will be quit first.
    @ViewState var runningAtOpen: [String] = []

    /// The most log lines shown: `brew upgrade` can print thousands, and the panel re-lays out on each one.
    private static let logLines = 500

    var items: [UpdateItem] { job.rows("update", as: UpdateItem.init(fields:)) }
    var notes: UpdateNotes { UpdateNotes(meta: job.meta) }
    var hasBrew: Bool { !notes.noBrew }
    /// The banner after an apply. Kept in the job, so a multi-minute `brew upgrade` still shows its result after the
    /// user looked at another screen (or switched language) meanwhile.
    var outcome: UpdateOutcome? { job.outcome as? UpdateOutcome }

    var body: some View {
        let items = items
        let chosen = items.filter { selected.contains($0.id) }
        ScreenScaffold {
            ScanBar(job: job, title: Screen.updates.title, scanLabel: L("Cek update", "Check for updates"), onScan: scan)
        } content: {
            content(items, chosen: chosen)
        } footer: {
            if job.actionHasFailure("finder_denied") {  // a DMG app could not go to the Trash
                PermissionCallout(kind: .automation,
                                  message: L("Izinkan Mac Cleaner mengendalikan Finder supaya bisa memindahkan aplikasi lama ke Trash.",
                                             "Allow Mac Cleaner to control Finder so it can move the old app to the Trash."))
            }
            outcomeView
            // The action's log, and the scan's while it runs (it can take minutes); not a finished scan's own lines.
            if job.showsLog || (job.phase == .scanning && !job.log.isEmpty) {
                LogPanel(job: job, maxLines: Self.logLines)
            }
        }
        .sheet(isPresented: $confirming) { confirmSheet(chosen) }
    }

    @ViewBuilder private func content(_ items: [UpdateItem], chosen: [UpdateItem]) -> some View {
        switch job.screenContent {
        case .scanning:
            EmptyState(symbol: Screen.updates.symbol,
                       text: L("Memeriksa update… Ini bisa makan waktu beberapa menit.",
                               "Checking for updates… This can take a few minutes."))
        case .idle:
            EmptyState(symbol: job.scanWasCancelled ? "xmark.circle" : Screen.updates.symbol,
                       text: job.scanWasCancelled ? L("Dibatalkan.", "Cancelled.")
                                     : L("Tekan Cek update untuk mencari update aplikasi.",
                                         "Press Check for updates to look for app updates."))
        case .failed:
            Spacer(minLength: 0)  // ScanBar shows the message and Try again
        case .empty:
            VStack(alignment: .leading, spacing: 12) {
                EmptyState(symbol: "checkmark.circle",
                           text: L("Semua aplikasi yang bisa dicek sudah versi terbaru.",
                                   "Every app that could be checked is up to date."))
                notesView
            }
        case .list:
            VStack(alignment: .leading, spacing: 12) {
                selectAll(items)
                table(items)
                notesView
                actions(chosen)
            }
        }
    }

    // MARK: list

    private func selectAll(_ items: [UpdateItem]) -> some View {
        let all = Binding<Bool>(
            get: { !items.isEmpty && items.allSatisfy { selected.contains($0.id) } },
            set: { selected = $0 ? Set(items.map(\.id)) : [] })
        return HStack {
            Toggle(L("Pilih semua", "Select all"), isOn: all).disabled(job.isBusy)
            Spacer()
            Text(L("\(selected.count) dari \(items.count) dipilih", "\(selected.count) of \(items.count) selected"))
                .foregroundStyle(.secondary)
        }
    }

    private func table(_ items: [UpdateItem]) -> some View {
        Table(items) {
            TableColumn("") { item in
                Toggle(item.name, isOn: binding(item.id)).labelsHidden().disabled(job.isBusy)
            }
            .width(24)
            TableColumn(L("Nama", "Name")) { item in
                Text(item.name).lineLimit(1).help(item.ref.isEmpty ? item.name : item.ref)
            }
            TableColumn(L("Terpasang", "Installed")) { item in
                Text(item.from.isEmpty ? "?" : item.from).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn(L("Terbaru", "Latest")) { item in
                Text(item.to).foregroundStyle(.green)
            }
            .width(min: 70, ideal: 90)
            TableColumn(L("Update lewat", "Update via")) { item in
                Text(item.via).lineLimit(1)
            }
            .width(min: 110, ideal: 150)
        }
        .screenTable()
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }

    // MARK: notes

    @ViewBuilder private var notesView: some View {
        let notes = notes
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if notes.noBrew {
                    warning(L("Homebrew tidak ditemukan. Aplikasi DMG tetap dicek, tapi update-nya lewat halaman download.",
                              "Homebrew not found. DMG apps are still checked, but you'll get their download page to update."))
                }
                if notes.offline {
                    warning(L("Katalog Homebrew tidak bisa dibaca (offline?) — hanya aplikasi dengan updater Sparkle yang dicek.",
                              "Couldn't read Homebrew's catalog (offline?) — only apps with a Sparkle updater are checked."))
                }
                if notes.pinned > 0 {
                    Text(L("\(notes.pinned) formula di-pin dilewati (brew unpin <nama> untuk mengizinkan update).",
                           "\(notes.pinned) pinned formula(e) skipped (brew unpin <name> to allow updates)."))
                        .foregroundStyle(.secondary)
                }
                if !notes.autoSkip.isEmpty {
                    let names = notes.autoSkip.joined(separator: ", ")
                    Text(L("Tidak dicek (cask yang update sendiri, aplikasinya tidak ada di Applications): \(names)",
                           "Not checked (self-updating casks with no app in Applications): \(names)"))
                        .foregroundStyle(.secondary)
                }
                if notes.masCount > 0 { masNote(notes) }
            }
            .font(.callout)
        }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func masNote(_ notes: UpdateNotes) -> some View {
        HStack(spacing: 8) {
            Text(L("\(notes.masCount) aplikasi dari App Store — update-nya di App Store.",
                   "\(notes.masCount) App Store app(s) — update them in the App Store."))
            if !notes.hasMas {
                Text(L("(pasang 'mas' untuk cek dari sini)", "(install 'mas' to check them here)")).foregroundStyle(.secondary)
            }
            if notes.showsAppStoreButton {
                Button(L("Buka App Store", "Open App Store")) {
                    if let url = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    // MARK: result

    @ViewBuilder private var outcomeView: some View {
        if let outcome {
            switch outcome {
            case .done:
                banner(L("Update selesai.", "Updates finished."), symbol: "checkmark.circle.fill", color: .green)
            case .dryRun:
                banner(L("Mode coba: tidak ada yang diupdate.", "Dry run: nothing was updated."), symbol: "info.circle.fill", color: .blue)
            case .skipped:
                banner(L("Tidak ada update yang dijalankan — lihat log di bawah.", "No updates were run — see the log below."),
                       symbol: "exclamationmark.triangle.fill", color: .orange)
            case .failed(let rechecked):
                // Also what a dismissed password dialog looks like: Homebrew's step fails, the engine goes on.
                banner(L("Sebagian update gagal atau tidak dijalankan (mis. dialog password ditutup) — lihat log di bawah.",
                         "Some updates failed or didn't run (for example, the password dialog was closed) — see the log below.")
                       + (rechecked ? " " + L("Daftar sudah diperiksa ulang.", "The list was checked again.") : ""),
                       symbol: "exclamationmark.triangle.fill", color: .orange)
            }
        }
    }

    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: confirm

    private func actions(_ chosen: [UpdateItem]) -> some View {
        HStack {
            OtherTaskNote(job: job)
            Spacer()
            Button(chosen.isEmpty ? L("Update terpilih", "Update selected")
                                  : L("Update terpilih", "Update selected") + " · \(chosen.count)") {
                runningAtOpen = appState.dryRun ? []
                    : AppQuitter.runningPaths(among: UpdateLogic.dmgAppsToCheck(selected: chosen, hasBrew: hasBrew))
                confirming = true
            }
            .disabled(chosen.isEmpty || job.isBusy || appState.anyRunning)
        }
    }
}
