import MacCleanerCore
import SwiftUI

/// The "All at once" section: one button per prune action, each behind a `ConfirmSheet`.
struct DockerAllAtOnce: View {
    /// An action waiting for its confirmation. `containers` only matters for the quick clean.
    private struct Pending: Identifiable {
        let action: DockerAction
        let containers: QuickCleanContainers
        var id: String { action.rawValue }
    }

    @ObservedObject var job: JobModel
    @Binding var expanded: Bool
    let afterAction: () async -> Void
    @EnvironmentObject private var appState: AppState
    @ViewState private var pending: Pending?
    @ViewState private var preparing = false

    private var engine: String? { job.meta["engine"] }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(DockerAction.allAtOnce(engine: engine)) { action in
                    GridRow {
                        Button(action.buttonTitle, role: action.typedWord(lang: appState.lang) == nil ? nil : .destructive) {
                            Task { await prepare(action) }
                        }
                        .gridColumnAlignment(.leading)
                        Text(action.blurb).foregroundStyle(.secondary)
                    }
                }
                if DockerAction.showsDesktopShrinkHint(engine: engine) {
                    Text(L("Mengecilkan disk Docker Desktop: Docker Desktop › Troubleshoot › Clean / Purge data",
                           "To shrink Docker Desktop's disk: Docker Desktop › Troubleshoot › Clean / Purge data"))
                        .foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
            }
            .disabled(job.isBusy || preparing || appState.anyRunning)
            .padding(.top, 6)
        } label: {
            Text(L("Sekaligus", "All at once")).font(.headline)
        }
        .sheet(item: $pending) { pending in
            dockerPruneSheet(pending.action, lang: appState.lang, dryRun: appState.dryRun,
                             counts: DockerCounts(meta: job.meta), containers: pending.containers) {
                await job.run(["docker-prune", pending.action.rawValue])
                await afterAction()
            }
        }
    }

    /// The quick clean lists the stopped containers it will remove, so they are read first (in a job of their own:
    /// the list on screen stays as it is). If that fails the sheet still opens and still says stopped containers go.
    private func prepare(_ action: DockerAction) async {
        guard action == .safe else { pending = Pending(action: action, containers: .listed([])); return }
        preparing = true
        let probe = appState.makeJob()
        await probe.scan(["docker-list", "containers"])
        pending = Pending(action: action,
                          containers: QuickCleanContainers(probeSucceeded: probe.phase == .done,
                                                           containers: probe.rows("container", as: DockerContainer.init(fields:))))
        preparing = false
    }
}

/// The confirmation of a prune action. Every one asks; the riskiest ask for a typed word too.
@MainActor func dockerPruneSheet(_ action: DockerAction, lang: String, dryRun: Bool, counts: DockerCounts?,
                                 containers: QuickCleanContainers = .listed([]),
                                 onConfirm: @escaping () async -> Void) -> ConfirmSheet {
    ConfirmSheet(
        title: dockerTitle(action.confirmTitle(containers: containers), dryRun: dryRun),
        items: containers.stopped.map { "\($0.name) (\($0.image), \($0.state))" },
        warning: action.warning(counts: counts, containers: containers),
        typedWord: action.typedWord(lang: lang),
        confirmLabel: action.confirmLabel,
        onConfirm: onConfirm)
}

/// A confirmation title, with the dry-run note when nothing will really be deleted.
@MainActor func dockerTitle(_ title: String, dryRun: Bool) -> String {
    title + (dryRun ? L(" (mode coba: tidak ada yang dihapus)", " (dry run: nothing is deleted)") : "")
}

extension JobModel {
    /// Runs `docker-rm <type> --list <file>` with exactly `lines`; the list file is deleted afterwards.
    func dockerRemove(_ type: String, _ lines: [String]) async {
        guard !lines.isEmpty else { return }
        let file: URL
        do { file = try ListFile.write(lines) } catch {
            note(.err, L("Daftar sementara tidak bisa ditulis.", "Couldn't write the temporary list."))
            return
        }
        defer { try? FileManager.default.removeItem(at: file) }
        await run(["docker-rm", type, "--list", file.path])
    }
}

// The texts of the actions: the CLI's menu lines (L652-670) and confirmations.
extension DockerAction {
    @MainActor var buttonTitle: String {
        switch self {
        case .imagesUnused: L("Hapus semua image tak dipakai", "Remove all unused images")
        case .imagesDangling: L("Hapus yang dangling", "Remove dangling")
        case .buildAll: L("Build cache: hapus semua", "Build cache: remove all")
        case .buildOld: L("Build cache: lebih lama dari 7 hari", "Build cache: older than 7 days")
        case .networks: L("Network tak dipakai", "Unused networks")
        case .safe: L("Bersihkan cepat (aman)", "Quick clean (safe)")
        case .allUnused: L("Hapus semua yang tak dipakai", "Remove everything unused")
        case .wipe: L("Hapus SEMUA data Docker", "Delete ALL Docker data")
        case .orbReset: L("Factory reset OrbStack", "Factory reset OrbStack")
        }
    }

    /// The menu description shown beside the button.
    @MainActor var blurb: String {
        switch self {
        case .imagesUnused: L("image yang tidak dipakai container", "images no container uses")
        case .imagesDangling: L("image tanpa nama dan tidak dipakai", "untagged images nothing uses")
        case .buildAll: L("semua build cache", "all build cache")
        case .buildOld: L("hanya build cache yang lebih lama dari 7 hari", "only build cache older than 7 days")
        case .networks: L("network buatan sendiri yang tidak dipakai", "custom networks nothing uses")
        case .safe: L("container berhenti, image dangling, network, build cache",
                      "stopped containers, dangling images, networks, build cache")
        case .allUnused: L("+ semua image & volume tak dipakai (data)", "+ all unused images & volumes (data)")
        case .wipe: L("termasuk container yang sedang berjalan (reset)", "including running containers (reset)")
        case .orbReset: L("+ Linux machine & Kubernetes (reset)", "+ Linux machines & Kubernetes (reset)")
        }
    }

    @MainActor var confirmLabel: String {
        switch self {
        case .wipe: L("Hapus semua data", "Delete all data")
        case .orbReset: L("Reset OrbStack", "Reset OrbStack")
        default: L("Lanjut", "Continue")
        }
    }

    /// `containers` only matters for the quick clean: it names the stopped containers it removes, also when the
    /// probe that lists them failed (`container prune` runs anyway).
    @MainActor func confirmTitle(containers: QuickCleanContainers) -> String {
        switch self {
        case .imagesUnused: L("Hapus semua image yang tidak dipakai container?", "Remove every image not used by a container?")
        case .imagesDangling: L("Hapus semua image dangling (tanpa nama dan tidak dipakai)?", "Remove all dangling images (untagged and unused)?")
        case .buildAll: L("Hapus semua build cache?", "Remove all build cache?")
        case .buildOld: L("Hapus build cache yang lebih lama dari 7 hari?", "Remove build cache older than 7 days?")
        case .networks:
            L("Network buatan sendiri yang tidak dipakai container akan dihapus (bridge/host/none aman).",
              "Custom networks not used by any container will be removed (bridge/host/none are kept).")
        case .safe:
            switch containers {
            case .listed(let stopped) where !stopped.isEmpty:
                L("Bersihkan cepat: container yang berhenti di bawah ini, image dangling, network dan build cache akan dihapus.",
                  "Quick clean removes the stopped containers below, dangling images, networks and build cache.")
            case .listed:
                L("Bersihkan cepat: image dangling, network dan build cache. Lanjut?",
                  "Quick clean: dangling images, networks and build cache. Go ahead?")
            case .unknown:
                L("Bersihkan cepat: container yang berhenti, image dangling, network dan build cache. Lanjut?",
                  "Quick clean: stopped containers, dangling images, networks and build cache. Go ahead?")
            }
        case .allUnused:
            L("Akan dihapus: container yang berhenti, SEMUA image tak dipakai, network tak dipakai, build cache, dan SEMUA volume yang tidak dipakai container.",
              "Will remove: stopped containers, ALL unused images, unused networks, build cache and ALL volumes not used by a container.")
        case .wipe: L("Hapus SEMUA data Docker?", "Delete ALL Docker data?")
        case .orbReset: L("Factory reset OrbStack?", "Factory reset OrbStack?")
        }
    }

    @MainActor func warning(counts: DockerCounts?, containers: QuickCleanContainers) -> String? {
        let backup = L("Pastikan database/volume penting sudah di-backup.", "Make sure important databases/volumes are backed up.")
        switch self {
        case .safe:
            guard containers.mentionsContainers else { return nil }
            return L("File yang ditulis di dalam container (bukan di volume) ikut hilang. Volume TIDAK disentuh.",
                     "Files written inside these containers (not in volumes) will be lost. Volumes are NOT touched.")
        case .allUnused:
            return L("Termasuk data database proyek yang container-nya sudah 'docker compose down'. Tidak bisa dikembalikan.",
                     "This includes database data of projects stopped with 'docker compose down'. This cannot be undone.")
        case .wipe:
            let what = counts.map {
                L("\($0.containers) container (\($0.running) berjalan), \($0.images) image, \($0.volumes) volume, network & build cache",
                  "\($0.containers) containers (\($0.running) running), \($0.images) images, \($0.volumes) volumes, networks & build cache")
            } ?? L("container, image, volume, network & build cache", "containers, images, volumes, networks & build cache")
            return L("Ini menghapus SEMUA data Docker: ", "This deletes ALL Docker data: ") + what + ". " + backup
        case .orbReset:
            return L("Factory reset: menghapus SEMUA data OrbStack — container, image, volume, Kubernetes & Linux machine.",
                     "Factory reset: deletes ALL OrbStack data — containers, images, volumes, Kubernetes and Linux machines.") + " " + backup
        default: return nil
        }
    }
}
