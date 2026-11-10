import MacCleanerCore
import SwiftUI

/// What the Docker screen shows while the engine runs: the df summary, the Container / Image / Volume lists
/// and the "All at once" actions. Its `.task(id: tab)` loads the list for the selected tab, and runs again
/// whenever this view is rebuilt, which is how the list reloads after an action's status read.
struct DockerRunningView: View {
    @ObservedObject var job: JobModel
    @ObservedObject var list: JobModel
    @Binding var tab: DockerTab
    @Binding var showAllAtOnce: Bool
    let afterAction: () async -> Void

    private var df: [DockerDF] { job.rows("df", as: DockerDF.init(fields:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !df.isEmpty { summary }
            Picker("", selection: $tab) {
                Text("Container").tag(DockerTab.containers)
                Text("Image").tag(DockerTab.images)
                Text("Volume").tag(DockerTab.volumes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            switch tab {
            case .containers: DockerContainersList(job: job, list: list, reload: load, afterAction: afterAction)
            case .images: DockerImagesList(job: job, list: list, reload: load, afterAction: afterAction)
            case .volumes: DockerVolumesList(job: job, list: list, reload: load, afterAction: afterAction)
            }
            DockerAllAtOnce(job: job, expanded: $showAllAtOnce, afterAction: afterAction)
        }
        .task(id: tab) { await load() }
    }

    private func load() async {
        switch tab {
        case .containers: await list.scan(["docker-list", "containers"])
        case .images: await list.scan(["docker-list", "images"])
        case .volumes: await list.scan(["docker-list", "volumes"])
        }
    }

    private var summary: some View {
        Table(df) {
            TableColumn(L("Jenis", "Type"), value: \.type)
            TableColumn(L("Jumlah", "Total"), value: \.total).width(60)
            TableColumn(L("Aktif", "Active"), value: \.active).width(60)
            TableColumn(L("Ukuran", "Size"), value: \.size).width(min: 70, ideal: 90)
            TableColumn(L("Bisa dibersihkan", "Reclaimable"), value: \.reclaimable)
        }
        .frame(height: CGFloat(df.count) * 24 + 34)
    }
}

/// The loading, empty and failed states shared by the three lists; `content` is the table.
private struct DockerListShell<Content: View>: View {
    @ObservedObject var list: JobModel
    let hasItems: Bool
    let emptyText: String
    let reload: () async -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch list.screenContent {
        case .scanning, .idle:
            EmptyState(symbol: "hourglass", text: L("Memuat…", "Loading…"))
        case .failed:
            VStack(spacing: 10) {
                Label {
                    Text(list.failureText ?? "").textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Button(L("Coba lagi", "Try again")) { Task { await reload() } }
                if list.showsLog { LogPanel(job: list, maxLines: 50) }  // what "see the details below" points at
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            EmptyState(symbol: "checkmark.circle", text: emptyText)
        case .list:
            // The list job is shared by the three tabs: rows of another kind mean this tab's load is still to come.
            if hasItems { content() } else { EmptyState(symbol: "hourglass", text: L("Memuat…", "Loading…")) }
        }
    }
}

private func toggleBinding(_ selected: Binding<Set<String>>, _ id: String) -> Binding<Bool> {
    Binding(get: { selected.wrappedValue.contains(id) },
            set: { if $0 { selected.wrappedValue.insert(id) } else { selected.wrappedValue.remove(id) } })
}

// MARK: containers

private struct DockerContainersList: View {
    @ObservedObject var job: JobModel
    @ObservedObject var list: JobModel
    let reload: () async -> Void
    let afterAction: () async -> Void
    @EnvironmentObject private var appState: AppState
    @ViewState private var selected: Set<String> = []
    @ViewState private var confirming = false

    private var items: [DockerContainer] { list.rows("container", as: DockerContainer.init(fields:)) }

    var body: some View {
        let items = items
        let ids = DockerContainer.idsToRemove(items, selected: selected)
        DockerListShell(list: list, hasItems: !items.isEmpty, emptyText: L("Tidak ada container.", "No containers."), reload: reload) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(L("Semua yang berhenti", "All stopped")) { selected = Set(DockerContainer.stoppedIDs(items)) }
                    Spacer()
                }
                .disabled(job.isBusy)
                Table(items) {
                    TableColumn("") { item in
                        Toggle(item.name, isOn: toggleBinding($selected, item.id)).labelsHidden().disabled(job.isBusy)
                    }
                    .width(24)
                    TableColumn("Container", value: \.name)
                    TableColumn("Image", value: \.image)
                    TableColumn(L("Status", "State")) { item in ContainerStateLabel(container: item) }
                    .width(min: 70, ideal: 80)
                    TableColumn(L("Ukuran", "Size"), value: \.size).width(min: 60, ideal: 70)
                }
                HStack {
                    Spacer()
                    Button(ids.isEmpty ? L("Hapus", "Remove") : L("Hapus", "Remove") + " (\(ids.count))") { confirming = true }
                        .disabled(ids.isEmpty || job.isBusy)
                }
            }
            .sheet(isPresented: $confirming) { sheet(items.filter { selected.contains($0.id) }) }
        }
        .onChange(of: items.map(\.id)) { ids in selected.formIntersection(ids) }
    }

    private func sheet(_ chosen: [DockerContainer]) -> some View {
        let ids = chosen.map(\.id)
        let running = chosen.filter(\.stopsFirst).count  // running, paused or restarting: `rm -f` stops them first
        // The CLI's two warnings (L433-435).
        var warning = L("File di dalam container (bukan di volume) ikut hilang. Volume tidak disentuh.",
                        "Files inside these containers (not in volumes) are lost. Volumes are not touched.")
        if running > 0 {
            warning = L("\(running) container sedang berjalan dan akan dihentikan dulu.",
                        "\(running) running container(s) will be stopped first.") + " " + warning
        }
        return ConfirmSheet(
            title: dockerTitle(L("Hapus container yang dipilih?", "Remove the selected containers?"), dryRun: appState.dryRun),
            items: chosen.map { "\($0.name) · \($0.image) (\($0.state))" },
            warning: warning,
            typedWord: nil,
            confirmLabel: L("Hapus", "Remove"),
            onConfirm: { await remove(ids) })
    }

    private func remove(_ ids: [String]) async {
        selected = []
        await job.dockerRemove("containers", ids)
        await afterAction()
    }
}

// MARK: images

private struct DockerImagesList: View {
    private enum Pending: Identifiable {
        case selected, prune(DockerAction)
        var id: String { switch self { case .selected: "selected"; case .prune(let action): action.rawValue } }
    }

    @ObservedObject var job: JobModel
    @ObservedObject var list: JobModel
    let reload: () async -> Void
    let afterAction: () async -> Void
    @EnvironmentObject private var appState: AppState
    @ViewState private var selected: Set<String> = []
    @ViewState private var pending: Pending?

    private var items: [DockerImage] { list.rows("image", as: DockerImage.init(fields:)) }

    var body: some View {
        let items = items
        let refs = DockerImage.refsToRemove(items, selected: selected)
        DockerListShell(list: list, hasItems: !items.isEmpty, emptyText: L("Tidak ada image.", "No images."), reload: reload) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(DockerAction.imagesUnused.buttonTitle) { pending = .prune(.imagesUnused) }
                    Button(DockerAction.imagesDangling.buttonTitle) { pending = .prune(.imagesDangling) }
                    Spacer()
                }
                .disabled(job.isBusy)
                Table(items) {
                    TableColumn("") { item in
                        if item.isSelectable {  // an image a container uses has no checkbox
                            Toggle(item.ref, isOn: toggleBinding($selected, item.id)).labelsHidden().disabled(job.isBusy)
                        }
                    }
                    .width(24)
                    TableColumn("Image") { item in Text(item.status == .dangling ? "<none> (\(item.ref))" : item.ref) }
                    TableColumn(L("Ukuran", "Size"), value: \.size).width(min: 60, ideal: 70)
                    TableColumn(L("Dibuat", "Created"), value: \.created).width(min: 90, ideal: 110)
                    TableColumn("Status") { item in ImageStatusBadge(status: item.status) }.width(min: 80, ideal: 90)
                }
                HStack {
                    Spacer()
                    Button(refs.isEmpty ? L("Hapus", "Remove") : L("Hapus", "Remove") + " (\(refs.count))") { pending = .selected }
                        .disabled(refs.isEmpty || job.isBusy)
                }
            }
            .sheet(item: $pending) { pending in
                switch pending {
                case .selected: removeSheet(refs)
                case .prune(let action): pruneSheet(action)
                }
            }
        }
        .onChange(of: items.map(\.id)) { ids in selected.formIntersection(ids) }
    }

    private func removeSheet(_ refs: [String]) -> some View {
        ConfirmSheet(
            title: dockerTitle(L("Hapus image yang dipilih?", "Remove the selected images?"), dryRun: appState.dryRun),
            items: refs,
            warning: nil,
            typedWord: nil,
            confirmLabel: L("Hapus", "Remove"),
            onConfirm: { await remove(refs) })
    }

    private func pruneSheet(_ action: DockerAction) -> some View {
        dockerPruneSheet(action, lang: appState.lang, dryRun: appState.dryRun, counts: nil) {
            await job.run(["docker-prune", action.rawValue])
            await afterAction()
        }
    }

    private func remove(_ refs: [String]) async {
        selected = []
        await job.dockerRemove("images", refs)
        await afterAction()
    }
}

/// running (green), stopped (exited, created or dead, like the CLI), or Docker's own word for anything else
/// (paused, restarting…), which is not stopped.
private struct ContainerStateLabel: View {
    let container: DockerContainer

    var body: some View {
        if container.isRunning {
            Text(L("berjalan", "running")).foregroundStyle(.green)
        } else if container.isStopped {
            Text(L("berhenti", "stopped")).foregroundStyle(.secondary)
        } else {
            Text(verbatim: container.state).foregroundStyle(.orange)
        }
    }
}

private struct ImageStatusBadge: View {
    let status: ImageStatus

    var body: some View {
        let (label, color): (String, Color) = switch status {
        case .inUse: (L("dipakai", "in use"), .green)
        case .unused: (L("tak dipakai", "unused"), .orange)
        case .dangling: ("dangling", .orange)
        }
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: volumes

private struct DockerVolumesList: View {
    @ObservedObject var job: JobModel
    @ObservedObject var list: JobModel
    let reload: () async -> Void
    let afterAction: () async -> Void
    @EnvironmentObject private var appState: AppState
    @ViewState private var selected: Set<String> = []
    @ViewState private var confirming = false

    private var items: [DockerVolume] { list.rows("volume", as: DockerVolume.init(fields:)) }

    var body: some View {
        let items = items
        let names = DockerVolume.namesToRemove(items, selected: selected)
        DockerListShell(list: list, hasItems: !items.isEmpty, emptyText: L("Tidak ada volume.", "No volumes."), reload: reload) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(L("Pilih yang tak dipakai", "Select unused")) { selected = Set(DockerVolume.unusedNames(items)) }
                    Spacer()
                }
                .disabled(job.isBusy)
                Table(items) {
                    TableColumn("") { item in
                        if item.isSelectable {  // a volume a container uses has no checkbox
                            Toggle(item.name, isOn: toggleBinding($selected, item.id)).labelsHidden().disabled(job.isBusy)
                        }
                    }
                    .width(24)
                    TableColumn("Volume", value: \.name)
                    TableColumn(L("Ukuran", "Size"), value: \.size).width(min: 60, ideal: 70)
                    TableColumn(L("Dipakai oleh", "Used by")) { item in
                        if item.inUse {
                            Text(item.usedBy).foregroundStyle(.green)
                        } else {
                            Text(L("tak dipakai", "unused")).foregroundStyle(.orange)
                        }
                    }
                    .width(min: 100, ideal: 140)
                }
                HStack {
                    Spacer()
                    Button(names.isEmpty ? L("Hapus", "Remove") : L("Hapus", "Remove") + " (\(names.count))") { confirming = true }
                        .disabled(names.isEmpty || job.isBusy)
                }
            }
            .sheet(isPresented: $confirming) { sheet(names) }
        }
        .onChange(of: items.map(\.id)) { ids in selected.formIntersection(ids) }
    }

    private func sheet(_ names: [String]) -> some View {
        ConfirmSheet(
            title: dockerTitle(L("Hapus volume yang dipilih?", "Remove the selected volumes?"), dryRun: appState.dryRun),
            items: names,
            warning: L("Data di volume ini (mis. database) hilang permanen.", "The data in these volumes (e.g. databases) is gone for good."),
            typedWord: DockerAction.volumesTypedWord(lang: appState.lang),
            confirmLabel: L("Hapus", "Remove"),
            onConfirm: { await remove(names) })
    }

    private func remove(_ names: [String]) async {
        selected = []
        await job.dockerRemove("volumes", names)
        await afterAction()
    }
}
