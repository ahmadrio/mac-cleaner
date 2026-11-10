import Foundation
import Testing
@testable import MacCleanerCore

/// Every bundled demo fixture (app/Resources/demo/*.txt) must be a valid engine transcript: each line is
/// a well-formed record or a blank line, never a mangled `@@` line that would silently turn into log text.
@Suite struct DemoFixtureTests {
    private static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/demo")

    private static func fixtures() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func fixturesExist() throws {
        let names = try Self.fixtures().map(\.lastPathComponent)
        for required in ["env", "disk", "caches-scan", "caches-clean", "bigdata-scan", "ram-scan", "ram-purge",
                         "apps-scan", "apps-list", "uninstall-plan", "uninstall", "docker-status", "docker-list-containers",
                         "docker-list-images", "docker-list-volumes", "docker-rm-images", "docker-prune-safe",
                         "updates-scan", "updates-apply"] {
            #expect(names.contains(required + ".txt"), "missing \(required).txt")
        }
    }

    @Test func everyLineIsAValidRecord() throws {
        for url in try Self.fixtures() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.isEmpty {
                let event = ProtocolParser.parse(String(line))
                if case .plain = event {
                    Issue.record("\(url.lastPathComponent):\(index + 1) is not a valid record: \(line)")
                }
            }
        }
    }

    @Test func rowsFitTheirTypedModels() throws {
        for url in try Self.fixtures() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n") {
                guard case let .row(kind, fields) = ProtocolParser.parse(String(line)) else { continue }
                let ok: Bool
                switch kind {
                case "cache": ok = CacheItem(fields: fields) != nil
                case "dir": ok = DirUsage(fields: fields) != nil
                case "memapp": ok = MemApp(fields: fields) != nil
                case "memproc": ok = MemProc(fields: fields) != nil
                case "app": ok = AppUsage(fields: fields) != nil
                case "appname": ok = AppEntry(fields: fields) != nil
                case "leftover": ok = Leftover(fields: fields) != nil
                case "admin": ok = fields.count == 1
                case "df": ok = DockerDF(fields: fields) != nil
                case "container": ok = DockerContainer(fields: fields) != nil
                case "image": ok = DockerImage(fields: fields) != nil
                case "volume": ok = DockerVolume(fields: fields) != nil
                case "update": ok = UpdateItem(fields: fields) != nil
                default: ok = true  // other kinds belong to later tasks' fixtures and tests
                }
                #expect(ok, "\(url.lastPathComponent): bad \(kind) row: \(line)")
            }
        }
    }

    @Test func everyFixtureEndsTheWayTheEngineWould() throws {
        // `disk` and `env` end with their records; no fixture may contain an `exited` (the replay adds it).
        for url in try Self.fixtures() {
            // (a docker container's state is also called "exited", so look for the record, not the word)
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            #expect(!lines.contains { $0.hasPrefix("@@exited") })
        }
    }

    @Test @MainActor func cacheScanFixtureReplaysThroughTheJobModel() async {
        let engine = DemoEngine(fixtures: Self.dir, lineDelay: .zero)
        let job = JobModel(engine: engine, options: { EngineOptions(lang: "id", dryRun: false) })
        await job.scan(["caches-scan"])
        #expect(job.phase == .done)
        let items = job.rows("cache", as: CacheItem.init(fields:))
        #expect(items.count == job.rows.count)
        #expect(items.contains { $0.kb == -1 && $0.id == "trash" })  // R10: the Trash with unknown size
        let safe = CacheItem.totalKB(items.filter { $0.kind == .safe }, selected: Set(items.map(\.id)))
        let heavy = CacheItem.totalKB(items.filter { $0.kind == .heavy }, selected: Set(items.map(\.id)))
        #expect(job.meta["total_safe"] == String(safe))
        #expect(job.meta["total_heavy"] == String(heavy))
    }

    @Test @MainActor func foldersFixtureIsLargestFirst() async {
        let job = JobModel(engine: DemoEngine(fixtures: Self.dir, lineDelay: .zero),
                           options: { EngineOptions(lang: "id", dryRun: false) })
        await job.scan(["bigdata-scan"])
        let dirs = job.rows("dir", as: DirUsage.init(fields:))
        #expect(!dirs.isEmpty && dirs.count == job.rows.count)
        #expect(dirs.map(\.kb) == dirs.map(\.kb).sorted(by: >))
        #expect(job.meta["fda"] != nil)
    }

    @Test @MainActor func ramFixturesReplayThroughTheJobModel() async throws {
        let job = JobModel(engine: DemoEngine(fixtures: Self.dir, lineDelay: .zero),
                           options: { EngineOptions(lang: "id", dryRun: false) })
        await job.scan(["ram-scan"])
        #expect(job.phase == .done)
        let summary = try #require(MemSummary(meta: job.meta))
        #expect(summary.used == summary.app + summary.wired + summary.comp)
        #expect(summary.pressure != .unknown)
        let apps = job.rows("memapp", as: MemApp.init(fields:))
        let hosts = apps.filter { !$0.isSelectable }
        #expect(hosts.map(\.name) == ["Mac Cleaner"])
        #expect(apps.contains { $0.name == "Docker" && !$0.note.isEmpty })
        #expect(apps.map(\.kb) == apps.map(\.kb).sorted(by: >))
        let procs = job.rows("memproc", as: MemProc.init(fields:))
        #expect(procs.contains { $0.path.contains("Virtualization.VirtualMachine") && !$0.note.isEmpty })
        #expect(apps.count + procs.count == job.rows.count)

        await job.run(["ram-purge"])
        #expect(job.phase == .done)
        let pair = try #require(BeforeAfter(meta: job.meta, before: "cached_before", after: "cached_after"))
        #expect(pair.after < pair.before)
    }

    @Test @MainActor func appsFixturesReplayThroughTheJobModel() async throws {
        let job = JobModel(engine: DemoEngine(fixtures: Self.dir, lineDelay: .zero),
                           options: { EngineOptions(lang: "id", dryRun: false) })
        await job.scan(["apps-scan", "90"])
        #expect(job.phase == .done)
        let apps = job.rows("app", as: AppUsage.init(fields:))
        #expect(apps.count == job.rows.count)
        #expect(apps.map(\.kb) == apps.map(\.kb).sorted(by: >))
        #expect(apps.contains { $0.lastOpened == .never && $0.isRare })       // "never recorded"
        #expect(apps.contains { !$0.isRare && $0.lastOpened != .never })      // "active"
        #expect(apps.contains { $0.lastOpened == .today })
        #expect(!apps.contains { $0.name == "Mac Cleaner" })
        // The summary is over the rare apps (all of them are shown).
        let summary = try #require(AppsSummary(meta: job.meta))
        let rare = apps.filter(\.isRare)
        #expect(summary.rareCount == rare.count)
        #expect(summary.rareKB == rare.reduce(0) { $0 + $1.kb })
        #expect(summary.total >= apps.count)
        // An app is rare exactly when never recorded or unopened for more than the 90 days asked for.
        #expect(apps.allSatisfy { $0.isRare == ($0.days < 0 || $0.days > 90) })

        await job.scan(["apps-list"])
        let entries = job.rows("appname", as: AppEntry.init(fields:))
        #expect(entries.count == job.rows.count && !entries.isEmpty)
        #expect(!entries.contains { $0.name == "Mac Cleaner" })
        #expect(entries.allSatisfy { $0.path.hasPrefix("/Applications/") && $0.path.hasSuffix("/\($0.name).app") })
        #expect(entries.map(\.name) == entries.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test @MainActor func uninstallFixturesReplayThroughTheJobModel() async throws {
        let job = JobModel(engine: DemoEngine(fixtures: Self.dir, lineDelay: .zero),
                           options: { EngineOptions(lang: "id", dryRun: false) })
        await job.scan(["uninstall-plan", "/Applications/Blender.app"])
        #expect(job.phase == .done)
        let plan = try #require(UninstallPlan(appPath: "/Applications/Blender.app", meta: job.meta, rows: job.rows))
        #expect(plan.bundleID != nil && plan.dupPath == nil)
        #expect(!plan.leftovers.isEmpty && !plan.adminPaths.isEmpty)
        #expect(plan.leftovers.count == job.rows("leftover", as: Leftover.init(fields:)).count)
        #expect(plan.leftovers.allSatisfy { $0.path.hasPrefix("/Users/demo/Library/") })
        #expect(plan.adminPaths.allSatisfy { !$0.hasPrefix("/Users/") })

        await job.run(["uninstall", "/Applications/Blender.app", "--list", "/tmp/none"])
        #expect(job.phase == .done)
        #expect(job.log.contains { $0.level == .ok })
        #expect(job.failures.isEmpty)
    }

    @Test @MainActor func dockerFixturesReplayThroughTheJobModel() async throws {
        let job = JobModel(engine: DemoEngine(fixtures: Self.dir, lineDelay: .zero),
                           options: { EngineOptions(lang: "id", dryRun: false) })
        await job.scan(["docker-status"])
        #expect(job.phase == .done)
        #expect(DockerMode(meta: job.meta, failureCodes: []) == .running)
        #expect(job.meta["engine"] == "OrbStack")
        let counts = try #require(DockerCounts(meta: job.meta))
        let df = job.rows("df", as: DockerDF.init(fields:))
        #expect(df.count == job.rows.count && df.count == 4)

        await job.scan(["docker-list", "containers"])
        let containers = job.rows("container", as: DockerContainer.init(fields:))
        #expect(containers.count == counts.containers && containers.count == job.rows.count)
        #expect(containers.filter(\.isRunning).count == counts.running)
        #expect(!DockerContainer.stoppedIDs(containers).isEmpty)

        await job.scan(["docker-list", "images"])
        let images = job.rows("image", as: DockerImage.init(fields:))
        #expect(images.count == counts.images && images.count == job.rows.count)
        #expect(Set(images.map(\.status)) == [.inUse, .unused, .dangling])

        await job.scan(["docker-list", "volumes"])
        let volumes = job.rows("volume", as: DockerVolume.init(fields:))
        #expect(volumes.count == counts.volumes && volumes.count == job.rows.count)
        #expect(volumes.contains { $0.inUse && !$0.usedBy.isEmpty } && volumes.contains { !$0.inUse && $0.usedBy.isEmpty })

        await job.run(["docker-rm", "images", "--list", "/tmp/none"])
        #expect(job.phase == .done && job.freedKB != nil)
        await job.run(["docker-prune", "safe"])
        #expect(job.phase == .done && job.freedKB != nil)
    }

    @Test @MainActor func updatesFixturesReplayThroughTheJobModel() async throws {
        let job = JobModel(engine: DemoEngine(fixtures: Self.dir, lineDelay: .zero),
                           options: { EngineOptions(lang: "id", dryRun: false) })
        await job.scan(["updates-scan"])
        #expect(job.phase == .done)
        let items = job.rows("update", as: UpdateItem.init(fields:))
        #expect(items.count == job.rows.count)
        #expect(Set(items.map(\.kind)) == [.formula, .cask, .dmg, .sparkle, .mas])
        #expect(items.contains { $0.ref == "hashicorp/tap/terraform" })
        #expect(items.contains { $0.kind == .dmg && $0.app.hasSuffix(".app") && $0.homepage.hasPrefix("https://") })
        #expect(items.contains { $0.kind == .sparkle && !$0.app.isEmpty })
        #expect(items.allSatisfy { !$0.name.isEmpty && !$0.to.isEmpty && !$0.via.isEmpty })
        let notes = UpdateNotes(meta: job.meta)
        #expect(notes.pinned == 1 && notes.autoSkip == ["Zoom", "Firefox"] && notes.masCount == 3 && !notes.hasMas)
        #expect(!notes.noBrew && !notes.offline && notes.showsAppStoreButton)

        // The list file has the engine's seven fields per row.
        let lines = UpdateLogic.listLines(selected: items)
        #expect(lines.allSatisfy { $0.split(separator: "\t", omittingEmptySubsequences: false).count == 7 })

        await job.run(["updates-apply", "--list", "/tmp/none"])
        #expect(job.phase == .done)
        #expect(job.log.contains { $0.text.hasPrefix("$ brew upgrade --formula") })
        #expect(job.failures.isEmpty)
    }
}
