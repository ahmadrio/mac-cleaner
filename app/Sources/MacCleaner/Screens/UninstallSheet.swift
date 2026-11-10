import AppKit
import MacCleanerCore
import SwiftUI

/// The app a screen wants to uninstall; `.sheet(item:)` presents an `UninstallSheet` for it.
struct UninstallTarget: Identifiable {
    let path: String
    var id: String { path }
}

/// A path with the home folder shown as `~` (the demo fixtures use /Users/demo).
@MainActor func tildePath(_ path: String) -> String {
    PathFormat.tilde(path, home: EngineLocator.isDemo ? "/Users/demo" : NSHomeDirectory())
}

/// Uninstalls one app: shows its `uninstall-plan` (the app, its leftover files to tick, what is only
/// informational), and moves the app plus the ticked leftovers to the Trash. Used by the Rarely used apps and
/// Uninstall screens. It owns its job, so it works whichever screen opened it.
///
/// What is moved is exactly what the sheet lists: the app and the ticked leftovers, and the leftovers can only be
/// ones the plan returned (`UninstallPlan.listLines`). The engine checks the list again before it moves anything.
/// `onFinished` runs once the sheet is gone after an uninstall that really moved items (not after a dry run).
struct UninstallSheet: View {
    let appPath: String
    let onFinished: () -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var job: JobModel
    @ViewState private var checked: Set<String> = []
    @ViewState private var uninstalled = false
    @ViewState private var askingToQuit = false
    @ViewState private var listError: String?
    /// Set once an action has started, so the log shows the action's lines, not the plan scan's.
    @ViewState private var acted = false

    init(appPath: String, onFinished: @escaping () -> Void) {
        self.appPath = appPath
        self.onFinished = onFinished
        _job = StateObject(wrappedValue: AppState.shared.makeJob())
    }

    private var plan: UninstallPlan? { UninstallPlan(appPath: appPath, meta: job.meta, rows: job.rows) }
    private var appName: String { URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(20)
        .frame(width: 540)
        .task { await loadPlan() }
        .interactiveDismissDisabled(job.isBusy)
        .onDisappear { if uninstalled { onFinished() } }
        .alert(L("\(appName) sedang berjalan.", "\(appName) is running."), isPresented: $askingToQuit) {
            Button(L("Tutup", "Quit")) { Task { await quitThenUninstall() } }
            Button(L("Batal", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("Tutup \(appName) sekarang? Kalau ada pekerjaan yang belum disimpan, aplikasinya akan bertanya dulu.",
                   "Quit \(appName) now? If there's unsaved work, the app asks you first."))
        }
    }

    @ViewBuilder private var content: some View {
        if job.phase == .scanning || job.phase == .idle {
            loading
        } else if job.scanFailed {
            planFailed
        } else if let plan {
            planView(plan)
        } else {
            message(L("Rencana uninstall tidak bisa dibaca.", "The uninstall plan couldn't be read."))
            HStack { Spacer(); closeButton }
        }
    }

    // MARK: loading and failure

    private var loading: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Mencari file sisa \(appName)…", "Looking for \(appName)'s leftover files…")).font(.headline)
            ProgressView().progressViewStyle(.linear)
            HStack {
                Text(job.progress?.text ?? L("Membaca bundle ID semua aplikasi…", "Reading every app's bundle ID…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let p = job.progress, let step = p.step, let total = p.total {
                    Text(verbatim: "\(step)/\(total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(L("Batal", "Cancel")) { job.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private var planFailed: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appName).font(.headline)
            message(failureMessage ?? L("Gagal membaca rencana uninstall.", "Couldn't read the uninstall plan."))
            HStack {
                Spacer()
                closeButton
                Button(L("Coba lagi", "Try again")) { Task { await loadPlan() } }
            }
        }
    }

    // MARK: the plan

    private func planView(_ plan: UninstallPlan) -> some View {
        let dry = appState.dryRun
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.name).font(.title3.weight(.semibold))
                Text(plan.bundleID ?? L("bundle ID tidak diketahui", "unknown bundle ID"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(uninstalled ? L("Dipindahkan ke Trash:", "Moved to the Trash:")
                 : L("Akan dipindahkan ke Trash:", "Will be moved to the Trash:")
                    + (dry ? L(" (mode coba: tidak ada yang dipindahkan)", " (dry run: nothing is moved)") : ""))
                .font(.headline)
            itemBox(plan)
            notes(plan)
            Text(totalText(plan)).monospacedDigit()
            outcome
            HStack {
                Spacer()
                if uninstalled {
                    Button(L("Selesai", "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                } else {
                    Button(L("Batal", "Cancel"), role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(job.isBusy)
                    // No .defaultAction: Return must never move things to the Trash.
                    Button(L("Pindahkan ke Trash", "Move to Trash")) { moveToTrash(plan) }
                        .disabled(job.isBusy)
                }
            }
        }
    }

    /// The app, then the leftovers with a checkbox each. Together with the total, this is what will move.
    private func itemBox(_ plan: UninstallPlan) -> some View {
        let locked = job.isBusy || uninstalled
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                row(kb: plan.appKB, path: plan.appPath) {
                    Image(systemName: "app.fill").foregroundStyle(.secondary).frame(width: 18)
                }
                ForEach(plan.leftovers) { item in
                    row(kb: item.kb, path: item.path) {
                        Toggle(item.path, isOn: binding(item.path)).labelsHidden().disabled(locked)
                    }
                }
                if plan.leftovers.isEmpty && plan.dupPath == nil {
                    Text(L("Tidak ada file sisa di ~/Library.", "No leftover files in ~/Library."))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func row<Leading: View>(kb: Int, path: String, @ViewBuilder leading: () -> Leading) -> some View {
        HStack(spacing: 8) {
            leading()
            Text(ByteFormat.string(kb: kb)).monospacedDigit().frame(width: 72, alignment: .trailing)
            Text(tildePath(path)).lineLimit(1).truncationMode(.middle).help(path)
            Spacer(minLength: 0)
        }
    }

    /// The duplicate warning, the admin-only paths and the vendor hint (the CLI's texts).
    @ViewBuilder private func notes(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let dup = plan.dupPath {
                Label {
                    Text(L("Ada salinan lain aplikasi ini (\(tildePath(dup))), jadi file sisanya tidak disentuh.",
                           "Another copy of this app is installed (\(tildePath(dup))), so its files are kept."))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if !plan.adminPaths.isEmpty {
                Text(L("Juga ada di luar folder home (butuh izin admin, tidak dihapus):",
                       "Also found outside your home folder (needs admin, not removed):"))
                    .foregroundStyle(.secondary)
                ForEach(plan.adminPaths, id: \.self) { path in
                    Text(path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).padding(.leading, 12).help(path)
                }
            }
            if plan.vendorHint {
                Text(L("Aplikasi ini ada di folder sendiri (\(tildePath(plan.appFolder))) — cek apakah ada uninstaller dari vendornya.",
                       "This app lives in its own folder (\(tildePath(plan.appFolder))) — check whether the vendor ships an uninstaller."))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func totalText(_ plan: UninstallPlan) -> String {
        let n = plan.checkedLeftovers(checked).count
        return L("Total", "Total") + ": " + ByteFormat.string(kb: plan.totalKB(checked: checked))
            + "  (" + L("aplikasi + \(n) file sisa", "app + \(n) leftover file(s)") + ")"
    }

    // MARK: result

    @ViewBuilder private var outcome: some View {
        if job.hasFailure("finder_denied") {
            PermissionCallout(kind: .automation,
                              message: L("Izinkan Mac Cleaner mengendalikan Finder supaya bisa memindahkan item ke Trash.",
                                         "Allow Mac Cleaner to control Finder so it can move items to the Trash."))
        } else if let failure = failureMessage ?? listError {
            message(failure)
        }
        if acted, !job.log.isEmpty { LogPanel(job: job) }
        if acted, job.phase == .done, job.lastRunWasDryRun {
            Label(L("Mode coba: tidak ada yang dipindahkan.", "Dry run: nothing was moved."), systemImage: "info.circle.fill")
                .foregroundStyle(.blue)
        }
        if uninstalled {
            Label {
                Text(L("Ruang disk baru lega setelah Trash dikosongkan (layar Cache › Trash).",
                       "Disk space is freed once the Trash is emptied (Cache screen › Trash)."))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Label {
            Text(text).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    /// The engine's message for a failed job: `not_allowed` carries only the refused path, so it gets a lead-in.
    private var failureMessage: String? {
        guard case .failed(let text) = job.phase, !job.hasFailure("finder_denied") else { return nil }
        return job.hasFailure("not_allowed") ? L("Tidak diizinkan: ", "Not allowed: ") + text : job.failureText ?? text
    }

    private var closeButton: some View {
        Button(L("Tutup", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
    }

    private func binding(_ path: String) -> Binding<Bool> {
        Binding(get: { checked.contains(path) },
                set: { if $0 { checked.insert(path) } else { checked.remove(path) } })
    }

    // MARK: work

    private func loadPlan() async {
        listError = nil
        await job.scan(["uninstall-plan", appPath])
        // Everything is ticked to start with; a duplicate copy has no leftovers to tick.
        checked = Set(plan?.leftovers.map(\.path) ?? [])
    }

    /// Detecting a running app is read-only. Demo mode never looks (its quit is simulated, see `AppQuitter`),
    /// and a dry run doesn't check, like the CLI.
    private func moveToTrash(_ plan: UninstallPlan) {
        if !appState.dryRun, !EngineLocator.isDemo, isRunning(appPath) {
            askingToQuit = true
        } else {
            Task { await uninstall(plan) }
        }
    }

    private func isRunning(_ path: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains {
            $0 != NSRunningApplication.current && $0.bundleURL?.standardizedFileURL.path == path
        }
    }

    /// Asks the app to quit through `AppQuitter`; goes on only if it did.
    private func quitThenUninstall() async {
        guard let plan else { return }
        acted = true
        var quit = false
        await job.runLocal { job in
            quit = await AppQuitter.quit(appPaths: [appPath])[appPath] == true
            if !quit {
                job.note(.err, L("\(plan.name) belum tertutup — tutup manual, lalu ulangi.",
                                 "\(plan.name) is still running — quit it yourself, then try again."))
            }
        }
        if quit { await uninstall(plan) }
    }

    /// Writes the ticked leftovers to a list file, runs `uninstall`, deletes the file.
    private func uninstall(_ plan: UninstallPlan) async {
        listError = nil
        acted = true
        let list: URL
        do {
            list = try ListFile.write(plan.listLines(checked: checked))
        } catch {
            listError = L("Daftar file tidak bisa ditulis: ", "Couldn't write the file list: ") + error.localizedDescription
            return
        }
        defer { try? FileManager.default.removeItem(at: list) }
        await job.run(["uninstall", appPath, "--list", list.path])
        guard job.phase == .done else { return }
        if !job.lastRunWasDryRun {
            uninstalled = true
            await appState.refreshDisk()
        }
    }
}
