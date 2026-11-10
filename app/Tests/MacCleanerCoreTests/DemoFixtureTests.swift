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
        for required in ["env", "disk", "caches-scan", "caches-clean", "bigdata-scan"] {
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
                default: ok = true  // other kinds belong to later tasks' fixtures and tests
                }
                #expect(ok, "\(url.lastPathComponent): bad \(kind) row: \(line)")
            }
        }
    }

    @Test func everyFixtureEndsTheWayTheEngineWould() throws {
        // `disk` and `env` end with their records; no fixture may contain an `exited` (the replay adds it).
        for url in try Self.fixtures() {
            #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("exited"))
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
}
