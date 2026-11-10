import MacCleanerCore
import SwiftUI

/// The confirmation sheet, and the work behind it: quit the running DMG apps, write the list, run `updates-apply`.
extension UpdatesView {
    func confirmSheet(_ chosen: [UpdateItem]) -> some View {
        var warnings: [String] = []
        if UpdateLogic.replacesDMG(selected: chosen, hasBrew: hasBrew) {
            warnings.append(L("Aplikasi dari DMG diganti versi Homebrew: aplikasi lama dipindah ke Trash dulu, setting Anda tetap aman, dan selanjutnya aplikasi itu ikut diupdate lewat menu ini.",
                              "DMG apps are replaced with Homebrew's version: the old app goes to the Trash first, your settings stay, and from then on it's updated from this menu."))
        }
        if !runningAtOpen.isEmpty {
            let names = runningAtOpen.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }.joined(separator: ", ")
            warnings.append(L("Sedang berjalan, akan ditutup dulu: \(names). Kalau ada pekerjaan yang belum disimpan, aplikasinya akan bertanya dulu; yang belum tertutup dilewati.",
                              "Running, will be quit first: \(names). If there's unsaved work, the app asks you first; any that stay open are skipped."))
        }
        let needsPermission = UpdateLogic.needsAppManagement(selected: chosen)
        return ConfirmSheet(
            title: L("Akan diupdate:", "Will update:")
                + (appState.dryRun ? L(" (mode coba: tidak ada yang diupdate)", " (dry run: nothing is updated)") : ""),
            items: chosen.map(\.summaryLine),
            warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n"),
            accessory: needsPermission || hasBrew ? AnyView(sheetNotes(needsPermission: needsPermission)) : nil,
            typedWord: nil,
            confirmLabel: L("Update", "Update"),
            onConfirm: { await begin(chosen, quit: runningAtOpen) })
    }

    private func sheetNotes(needsPermission: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if needsPermission {
                PermissionCallout(kind: .appManagement,
                                  message: L("macOS mungkin meminta izin App Management supaya Mac Cleaner boleh mengganti aplikasi.",
                                             "macOS may ask for App Management permission so Mac Cleaner can replace apps."))
            }
            if hasBrew {
                Text(L("Homebrew mungkin meminta password untuk beberapa aplikasi.",
                       "Homebrew may ask for your password for some apps."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: work

    func scan() async {
        selected = []
        outcome = nil
        acted = false
        scanned = true
        await job.scan(["updates-scan"])
    }

    /// Rescans so the list drops what was updated, keeping the log of the action that came before.
    private func rescan() async {
        selected = []
        await job.scan(["updates-scan"], keepLog: true)
    }

    /// Quits the running DMG apps the sheet named (through `AppQuitter`, never forcibly), drops the ones that stayed open
    /// from the list with a log line, and applies the rest.
    private func begin(_ chosen: [UpdateItem], quit: [String]) async {
        outcome = nil
        acted = true
        var stillRunning: Set<String> = []
        if !quit.isEmpty {
            await job.runLocal { job in
                job.note(.info, L("Menutup aplikasi yang sedang berjalan…", "Quitting the running apps…"))
                let result = await AppQuitter.quit(appPaths: quit)
                stillRunning = Set(quit.filter { result[$0] != true })
            }
        }
        let split = UpdateLogic.deselectRunning(selected: chosen, stillRunning: stillRunning)
        await apply(split.remaining, skipped: split.deselectedNames)
    }

    /// Writes the rows to a list file and runs `updates-apply`; after a real run that went through, refreshes the
    /// disk number and rescans.
    private func apply(_ rows: [UpdateItem], skipped: [String]) async {
        guard !rows.isEmpty else {
            await job.runLocal { job in note(skipped, in: job) }
            outcome = .skipped
            return
        }
        let list: URL
        do {
            list = try ListFile.write(UpdateLogic.listLines(selected: rows))
        } catch {
            await job.runLocal { job in
                job.note(.err, L("Daftar update tidak bisa ditulis: ", "Couldn't write the update list: ") + error.localizedDescription)
            }
            outcome = .failed
            return
        }
        defer { try? FileManager.default.removeItem(at: list) }
        await job.run(["updates-apply", "--list", list.path])
        note(skipped, in: job)
        switch job.phase {
        case .done:
            outcome = job.lastRunWasDryRun ? .dryRun : .done
        case .failed:
            outcome = .failed
        default:
            break
        }
        guard job.phase == .done, !job.lastRunWasDryRun else { return }
        await appState.refreshDisk()
        await rescan()
    }

    private func note(_ names: [String], in job: JobModel) {
        for name in names {
            job.note(.warn, L("\(name) masih berjalan, jadi tidak diupdate. Tutup, lalu update lagi.",
                              "\(name) is still running, so it was not updated. Quit it, then update again."))
        }
    }
}
