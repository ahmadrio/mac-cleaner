import AppKit
import MacCleanerCore
import SwiftUI

/// "Check for Updates…": checks the latest release (`self-update-check`) each time it opens and, when that is newer,
/// shows its notes and replaces this app with it (`self-update-apply`), then opens the new version.
/// It can't be closed while the update runs; a dry run only downloads and checks.
struct SelfUpdateSheet: View {
    @ObservedObject var job: JobModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var notes: [String] { job.rows("note") { $0.first } }
    private var stage: SelfUpdateStage {
        SelfUpdateStage(phase: job.phase, hasActed: job.hasActed, meta: job.meta, notes: notes)
    }
    /// The release the check found; it stays while the update runs and after it.
    private var release: SelfUpdateRelease? { SelfUpdateRelease(meta: job.meta, notes: notes) }
    private var page: URL { release?.page ?? SelfUpdateRelease.releasesPage }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L("Pembaruan Mac Cleaner", "Mac Cleaner updates"), systemImage: "arrow.down.app")
                .font(.headline)
            content
            buttons
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(job.phase == .running)
        .task { await check() }
        .onDisappear { job.cancel() }  // a check still running; an update can't be in progress here
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        switch stage {
        case .checking:
            busy(L("Memeriksa versi terbaru…", "Checking for the latest version…"))
        case .checkFailed:
            failure(job.failureText ?? L("Versi terbaru tidak bisa diperiksa.", "Couldn't check for the latest version."))
        case .upToDate(let release):
            Label(L("Mac Cleaner \(release.current) sudah versi terbaru.", "Mac Cleaner \(release.current) is up to date."),
                  systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.multicolor)
        case .available(let release):
            available(release)
        case .applying:
            VStack(alignment: .leading, spacing: 10) {
                busy(job.progress?.text ?? L("Mengupdate Mac Cleaner…", "Updating Mac Cleaner…"))
                if job.showsLog { LogPanel(job: job, maxLines: 50) }
            }
        case .replaced:
            if EngineLocator.isDemo {
                Label(L("Mode demo: Mac Cleaner tidak dibuka ulang.", "Demo mode: Mac Cleaner isn't opened again."),
                      systemImage: "info.circle.fill")
            } else {
                busy(L("Membuka ulang Mac Cleaner…", "Opening Mac Cleaner again…"))
            }
        case .checkedOnly:
            Label(L("Mode coba: versi baru sudah diunduh dan dicek, tapi Mac Cleaner tidak diganti.",
                    "Dry run: the new version was downloaded and checked, but Mac Cleaner wasn't replaced."),
                  systemImage: "info.circle.fill")
        case .applyFailed:
            VStack(alignment: .leading, spacing: 10) {
                if job.actionHasFailure("app_management") {
                    PermissionCallout(kind: .appManagement,
                                      message: L("macOS perlu izin ini supaya Mac Cleaner boleh mengganti dirinya.",
                                                 "macOS needs this permission before Mac Cleaner may replace itself."))
                }
                failure(job.failureText ?? L("Update gagal.", "The update failed."))
                if job.showsLog { LogPanel(job: job, maxLines: 50) }
            }
        }
    }

    private func available(_ release: SelfUpdateRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Mac Cleaner \(release.latest) tersedia. Versi Anda \(release.current).",
                   "Mac Cleaner \(release.latest) is available. You have \(release.current)."))
            let lines = ReleaseNotes.section(release.notes, lang: appState.lang)
            if !lines.isEmpty { notesView(lines) }
            Text(L("Mac Cleaner akan mengunduh versi baru, mencocokkannya dengan rilis, menaruh versi lama di Trash, lalu membuka versi baru. Karena aplikasi ini belum dinotarisasi Apple, macOS mungkin meminta izinnya (seperti Full Disk Access atau App Management) lagi.",
                   "Mac Cleaner downloads the new version, checks it against the release, puts the old version in the Trash and opens the new one. Because the app isn't notarized by Apple, macOS may ask for its permissions (such as Full Disk Access or App Management) again."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if release.sizeBytes > 0 {
                Text(L("Ukuran unduhan: ", "Download size: ") + ByteFormat.string(kb: (release.sizeBytes + 1023) / 1024))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if appState.dryRun {
                Label(L("Mode coba: versi baru hanya diunduh dan dicek, Mac Cleaner tidak diganti.",
                        "Dry run: the new version is only downloaded and checked; Mac Cleaner isn't replaced."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
            }
            OtherTaskNote(job: job)
        }
    }

    private func notesView(_ lines: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    switch ReleaseNoteLine(line) {
                    case .heading(let text): Text(markdown(text)).font(.headline).padding(.top, 2)
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "•")
                            Text(markdown(text))
                        }
                    case .text(let text): Text(markdown(text))
                    case .blank: Spacer().frame(height: 2)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// Inline Markdown (bold, italic, code) of one line of the notes; the plain text if it doesn't parse.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func failure(_ text: String) -> some View {
        Label {
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    // MARK: buttons

    @ViewBuilder private var buttons: some View {
        HStack {
            switch stage {
            case .checkFailed, .applyFailed:
                Button(L("Buka halaman rilis", "Open the release page")) { NSWorkspace.shared.open(page) }
                Spacer()
                Button(L("Tutup", "Close"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Coba lagi", "Try again")) { Task { await check() } }
            case .available(let release):
                Spacer()
                Button(L("Nanti", "Later"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(appState.dryRun ? L("Unduh & cek (mode coba)", "Download & check (dry run)")
                                       : L("Update & buka ulang", "Update & reopen")) {
                    Task { await update(release) }
                }
                .disabled(appState.anyRunning)
            case .checking:
                Spacer()
                Button(L("Batal", "Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            case .applying:
                EmptyView()
            case .replaced:
                Spacer()
                if EngineLocator.isDemo {
                    Button(L("Tutup", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                }
            case .upToDate, .checkedOnly:
                Spacer()
                Button(L("Tutup", "Close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: work

    private func check() async {
        guard job.phase != .running else { return }
        await job.scan(["self-update-check"])
    }

    private func update(_ release: SelfUpdateRelease) async {
        await job.run(["self-update-apply", release.latest])
        guard case .replaced(let app) = stage, !EngineLocator.isDemo else { return }
        // macOS won't quit an app while a sheet is open, so the sheet closes first; RootView's onDismiss then opens
        // the new version and quits (`Relauncher.relaunchAfterUpdate`).
        appState.relaunchPath = app
        dismiss()
    }
}

/// Opens the app at `appPath` once this process has ended, then quits. The waiting is done by a small shell that
/// outlives the app, so the new version opens as a new process instead of bringing this one to the front.
/// Call it with no sheet open: macOS refuses to quit an app that shows one.
@MainActor enum Relauncher {
    /// Quits and has the new version opened. If the helper can't start or quitting is refused, the app stays open
    /// (without a helper left waiting to open it later) and says to reopen it by hand.
    static func relaunchAfterUpdate(appPath: String) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$2\"",
                            "sh", String(ProcessInfo.processInfo.processIdentifier), appPath]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        if (try? helper.run()) != nil {
            NSApp.terminate(nil)  // never returns once quitting goes ahead
            helper.terminate()    // quitting was refused: the helper must not open the app whenever it quits later
        }
        let alert = NSAlert()
        alert.messageText = L("Mac Cleaner sudah diperbarui.", "Mac Cleaner is updated.")
        alert.informativeText = L("Keluar, lalu buka Mac Cleaner lagi untuk memakai versi baru.",
                                  "Quit, then open Mac Cleaner again to use the new version.")
        alert.runModal()
    }
}
