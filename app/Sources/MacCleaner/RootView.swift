import MacCleanerCore
import SwiftUI

/// The seven screens, in sidebar order.
enum Screen: CaseIterable, Hashable {
    case cache, docker, apps, uninstall, folders, updates, ram

    @MainActor var title: String {
        switch self {
        case .cache: L("Bersihkan cache", "Clean caches")
        case .docker: "Docker"
        case .apps: L("Aplikasi jarang dipakai", "Rarely used apps")
        case .uninstall: L("Uninstall aplikasi", "Uninstall apps")
        case .folders: L("Folder terbesar", "Largest folders")
        case .updates: L("Update aplikasi", "Update apps")
        case .ram: "RAM"
        }
    }

    var symbol: String {
        switch self {
        case .cache: "trash"
        case .docker: "shippingbox"
        case .apps: "square.grid.2x2"
        case .uninstall: "xmark.bin"
        case .folders: "folder"
        case .updates: "arrow.down.circle"
        case .ram: "memorychip"
        }
    }
}

/// The window: the sidebar with the disk bar, the selected screen under the dry-run banner, and the toolbar
/// with the language menu and the dry-run switch. Only an error when the engine script is missing.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @ViewState private var screen: Screen? = .cache

    var body: some View {
        if appState.engine == nil {
            EmptyState(symbol: "exclamationmark.triangle",
                       text: L("Mesin Mac Cleaner (mac-cleaner.command) tidak ditemukan di dalam aplikasi. Unduh ulang Mac Cleaner, lalu buka lagi.",
                               "Mac Cleaner's engine (mac-cleaner.command) is missing from the app. Download Mac Cleaner again, then reopen it."))
                .frame(minWidth: 480, minHeight: 320)
        } else {
            NavigationSplitView {
                List(Screen.allCases, id: \.self, selection: $screen) { screen in
                    Label(screen.title, systemImage: screen.symbol)
                }
                .safeAreaInset(edge: .bottom) { diskBar }
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            } detail: {
                VStack(spacing: 0) {
                    if appState.dryRun { dryRunBanner }
                    detail
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    languageMenu
                    Toggle(L("Mode coba", "Dry run"), isOn: $appState.dryRun)
                        .toggleStyle(.switch)
                        .help(L("Tampilkan yang akan dihapus tanpa menghapus apa pun",
                                "Show what would be deleted without deleting anything"))
                }
            }
            .navigationTitle("Mac Cleaner")
            .frame(minWidth: 760, minHeight: 480)
            // L() texts don't observe the language; rebuilding the content on a switch updates them all.
            .id(appState.lang)
            .task {
                await appState.loadEnv()
                await appState.refreshDisk()
                if let directory = Snapshot.directory {  // dev only: demo mode + MAC_CLEANER_SNAPSHOT_DIR
                    await Snapshot.run(into: directory, appState: appState) { screen = $0 }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch screen ?? .cache {
        case .cache: CacheView(job: appState.cache)
        case .docker: DockerView(job: appState.docker)
        case .apps: AppsView(job: appState.apps)
        case .uninstall: UninstallView(job: appState.uninstall)
        case .folders: FoldersView(job: appState.folders)
        case .updates: UpdatesView(job: appState.updates)
        case .ram: RAMView(job: appState.ram)
        }
    }

    private var dryRunBanner: some View {
        Label(L("Mode coba: tidak ada yang benar-benar dihapus", "Dry run: nothing will actually be deleted"),
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.medium))
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.yellow.opacity(0.3))
    }

    private var languageMenu: some View {
        Picker(selection: Binding(get: { appState.lang },
                                  set: { lang in Task { await appState.setLang(lang) } })) {
            // Language names stay in their own language.
            Text(verbatim: "Bahasa Indonesia").tag("id")
            Text(verbatim: "English").tag("en")
        } label: {
            Label(L("Bahasa", "Language"), systemImage: "globe")
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(L("Bahasa", "Language"))
    }

    private var diskBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Disk", systemImage: "internaldrive").font(.caption.weight(.semibold))
            if let disk = appState.disk, disk.totalKB > 0 {
                let used = Double(disk.totalKB - disk.freeKB) / Double(disk.totalKB)
                ProgressView(value: min(max(used, 0), 1))
                    .tint(used > 0.9 ? .red : .accentColor)
                Text(verbatim: "\(ByteFormat.string(kb: disk.freeKB)) \(L("kosong", "free")) \(L("dari", "of")) \(ByteFormat.string(kb: disk.totalKB))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: "–").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}
