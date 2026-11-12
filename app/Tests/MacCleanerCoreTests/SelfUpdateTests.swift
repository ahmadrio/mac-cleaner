import Foundation
import Testing
@testable import MacCleanerCore

@Suite struct SelfUpdateTests {
    private let checkMeta = ["current": "2.1.0", "latest": "2.2.0", "newer": "1",
                             "page": "https://github.com/ahmadrio/mac-cleaner/releases/tag/v2.2.0", "size": "1765971"]

    // MARK: release

    @Test func releaseReadsTheCheck() throws {
        let release = try #require(SelfUpdateRelease(meta: checkMeta, notes: ["a", ""]))
        #expect(release.current == "2.1.0")
        #expect(release.latest == "2.2.0")
        #expect(release.isNewer)
        #expect(release.page?.absoluteString == "https://github.com/ahmadrio/mac-cleaner/releases/tag/v2.2.0")
        #expect(release.sizeBytes == 1_765_971)
        #expect(release.notes == ["a", ""])
    }

    @Test func releaseNeedsBothVersionsAndAClearNewer() {
        for key in ["current", "latest", "newer"] {
            var meta = checkMeta
            meta[key] = nil
            #expect(SelfUpdateRelease(meta: meta, notes: []) == nil, "without \(key)")
            meta[key] = ""
            #expect(SelfUpdateRelease(meta: meta, notes: []) == nil, "with an empty \(key)")
        }
        var meta = checkMeta
        meta["newer"] = "yes"
        #expect(SelfUpdateRelease(meta: meta, notes: []) == nil)
    }

    @Test func releaseDropsAPageThatIsNotHTTPSAndABadSize() throws {
        var meta = checkMeta
        meta["page"] = "file:///etc/passwd"
        meta["size"] = "-5"
        let release = try #require(SelfUpdateRelease(meta: meta, notes: []))
        #expect(release.page == nil)
        #expect(release.sizeBytes == 0)
        meta["size"] = "big"
        #expect(SelfUpdateRelease(meta: meta, notes: [])?.sizeBytes == 0)
    }

    // MARK: stage

    private func stage(_ phase: JobModel.Phase, acted: Bool = false, _ meta: [String: String] = [:]) -> SelfUpdateStage {
        SelfUpdateStage(phase: phase, hasActed: acted, meta: meta, notes: [])
    }

    @Test func theCheckIsAvailableOrUpToDate() {
        guard case .available(let release) = stage(.done, checkMeta) else { Issue.record("not available"); return }
        #expect(release.latest == "2.2.0")
        var same = checkMeta
        same["latest"] = "2.1.0"
        same["newer"] = "0"
        guard case .upToDate = stage(.done, same) else { Issue.record("not up to date"); return }
    }

    @Test func aCheckWithoutAnAnswerOrThatFailedIsCheckFailed() {
        #expect(stage(.done, [:]) == .checkFailed)
        #expect(stage(.failed("offline")) == .checkFailed)
    }

    @Test func checkingAndApplying() {
        #expect(stage(.idle) == .checking)
        #expect(stage(.scanning) == .checking)
        #expect(stage(.running, acted: true, checkMeta) == .applying)
    }

    @Test func anUpdateEndsReplacedCheckedOnlyOrFailed() {
        var meta = checkMeta
        meta["replaced"] = "1"
        meta["app"] = "/Applications/Mac Cleaner.app"
        #expect(stage(.done, acted: true, meta) == .replaced(appPath: "/Applications/Mac Cleaner.app"))
        meta["replaced"] = "0"
        #expect(stage(.done, acted: true, meta) == .checkedOnly)  // dry run
        meta["replaced"] = "1"
        meta["app"] = ""
        #expect(stage(.done, acted: true, meta) == .checkedOnly)  // no path to open: never relaunch blindly
        #expect(stage(.failed("bad_download"), acted: true, meta) == .applyFailed)
    }

    @Test @MainActor func demoFixturesReplayThroughTheJobModel() async {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/demo")
        let job = JobModel(engine: DemoEngine(fixtures: fixtures, lineDelay: .zero),
                           options: { EngineOptions(lang: "en", dryRun: false) })
        let notes: () -> [String] = { job.rows("note") { $0.first } }
        await job.scan(["self-update-check"])
        let checked = SelfUpdateStage(phase: job.phase, hasActed: job.hasActed, meta: job.meta, notes: notes())
        guard case .available(let release) = checked else { Issue.record("check: \(checked)"); return }
        #expect(ReleaseNotes.section(release.notes, lang: "id").contains { $0.contains("Periksa Pembaruan") })
        await job.run(["self-update-apply", release.latest])
        let applied = SelfUpdateStage(phase: job.phase, hasActed: job.hasActed, meta: job.meta, notes: notes())
        #expect(applied == .replaced(appPath: "/Applications/Mac Cleaner.app"))
    }

    // MARK: notes

    private let notes = ["## Mac Cleaner 2.1.0", "", "English text.", "", "---", "", "## Mac Cleaner 2.1.0", "",
                         "Teks Indonesia.", "", "---", "", "SHA-256 `x`", ""]

    @Test func notesPickTheUILanguage() {
        #expect(ReleaseNotes.section(notes, lang: "en") == ["## Mac Cleaner 2.1.0", "", "English text."])
        #expect(ReleaseNotes.section(notes, lang: "id") == ["## Mac Cleaner 2.1.0", "", "Teks Indonesia."])
    }

    @Test func notesWithoutASeparatorAreShownWhole() {
        #expect(ReleaseNotes.section(["", "Only one", "  ", "language", ""], lang: "id") == ["Only one", "  ", "language"])
        #expect(ReleaseNotes.section([], lang: "en").isEmpty)
        #expect(ReleaseNotes.section(["", " "], lang: "en").isEmpty)
    }

    @Test func noteLines() {
        #expect(ReleaseNoteLine("## Mac Cleaner 2.1.0") == .heading("Mac Cleaner 2.1.0"))
        #expect(ReleaseNoteLine("### New") == .heading("New"))
        #expect(ReleaseNoteLine("- **Docker** tab") == .bullet("**Docker** tab"))
        #expect(ReleaseNoteLine("  * star") == .bullet("star"))
        #expect(ReleaseNoteLine("-no space") == .text("-no space"))
        #expect(ReleaseNoteLine("   ") == .blank)
        #expect(ReleaseNoteLine("Plain `code`.") == .text("Plain `code`."))
    }
}
