import AppKit
import SwiftUI

@main
struct MacCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Snapshot.prepare()  // dev only (demo mode + MAC_CLEANER_SNAPSHOT_DIR): the window's capture size
    }

    var body: some Scene {
        Window("Mac Cleaner", id: "main") {
            RootView().environmentObject(AppState.shared)
        }
        .defaultSize(width: 960, height: 640)
        .commands { SelfUpdateCommands(appState: AppState.shared) }
    }
}

/// "Check for Updates…" under "About Mac Cleaner". It observes AppState so its title follows the language.
struct SelfUpdateCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L("Periksa Pembaruan…", "Check for Updates…")) { appState.showsSelfUpdate = true }
                .disabled(appState.engine == nil || appState.showsSelfUpdate)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// An action (cleaning, uninstalling, updating…) must never be cut off, so quitting waits for it.
    /// Scans are cancelled with their whole process group.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppState.shared
        if state.anyRunning {
            let alert = NSAlert()
            alert.messageText = L("Tunggu sampai proses selesai.", "Please wait until the current task finishes.")
            alert.runModal()
            return .terminateCancel
        }
        state.cancelScans()
        return .terminateNow
    }
}
