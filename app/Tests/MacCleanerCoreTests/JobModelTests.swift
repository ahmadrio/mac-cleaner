import Foundation
import Testing
@testable import MacCleanerCore

/// An `EngineClient` for JobModel tests. Each `start` replays the next script and ends. With no script left,
/// the job stays open and the test plays the engine with `send`; `cancel()` then ends it with exit 143, as
/// SIGTERM would, unless `exitOnCancel` is false.
private final class FakeEngine: EngineClient, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[EngineEvent]]
    private var streams: [AsyncStream<EngineEvent>.Continuation] = []
    private var started: [(command: [String], options: EngineOptions)] = []
    private var cancelCount = 0
    private var ended = false  // set by endAll(): later jobs end at once too
    private let exitOnCancel: Bool

    init(_ scripts: [EngineEvent]..., exitOnCancel: Bool = true) {
        self.scripts = scripts
        self.exitOnCancel = exitOnCancel
    }

    var commands: [[String]] { lock.withLock { started.map(\.command) } }
    var options: [EngineOptions] { lock.withLock { started.map(\.options) } }
    var cancels: Int { lock.withLock { cancelCount } }

    func start(_ command: [String], options: EngineOptions) -> EngineJob {
        let (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
        let script: [EngineEvent]? = lock.withLock {
            started.append((command, options))
            streams.append(continuation)
            if ended { return [.exited(0)] }
            return scripts.isEmpty ? nil : scripts.removeFirst()
        }
        if let script { send(script, to: continuation) }
        let exitOnCancel = exitOnCancel
        return EngineJob(events: events, onCancel: { [self] in
            lock.withLock { cancelCount += 1 }
            if exitOnCancel { send([.exited(143)], to: continuation) }
        })
    }

    /// Plays the engine for the `job`-th started job (0-based); an `.exited` ends it.
    func send(_ events: EngineEvent..., job: Int) {
        send(events, to: lock.withLock { streams[job] })
    }

    /// Ends every open job, and every later one at once, with exit 0. JobModel ignores task cancellation by
    /// design, so the suite's time limit can't stop a test awaiting a job that a regression left open: call
    /// this before such awaits.
    func endAll() {
        let open = lock.withLock { ended = true; return streams }
        open.forEach { send([.exited(0)], to: $0) }
    }

    private func send(_ events: [EngineEvent], to continuation: AsyncStream<EngineEvent>.Continuation) {
        for event in events {
            continuation.yield(event)
            if case .exited = event { continuation.finish() }
        }
    }
}

private let en = EngineOptions(lang: "en", dryRun: false)

@MainActor private func model(_ engine: FakeEngine) -> JobModel { JobModel(engine: engine, options: { en }) }

/// Lets other main-actor work (the model consuming events) run until `condition` holds.
@MainActor private func settle(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<10_000 where !condition() { await Task.yield() }
    return condition()
}

private let npmRow = EngineEvent.row("cache", ["npm", "2048", "safe", "npm / npx cache"])

@Suite(.timeLimit(.minutes(1)))
@MainActor struct JobModelTests {
    @Test func scanCollectsRowsAndMeta() async {
        let job = model(FakeEngine([.progress("Scanning caches", step: 1, total: 2), npmRow,
                                    .meta("total_safe", "2048"), .exited(0)]))
        await job.scan(["caches-scan"])
        #expect(job.phase == .done)
        #expect(job.rows == [EngineRow(kind: "cache", fields: ["npm", "2048", "safe", "npm / npx cache"])])
        #expect(job.rows("cache", as: CacheItem.init(fields:)).map(\.id) == ["npm"])
        #expect(job.rows("dir", as: DirUsage.init(fields:)).isEmpty)
        #expect(job.meta["total_safe"] == "2048")
        #expect(job.progress == nil)
        #expect(!job.isBusy)
    }

    @Test func diskCommandReportsDisk() async {
        let job = model(FakeEngine([.disk(total: 500_000, free: 120_000), .exited(0)]))
        await job.scan(["disk"])
        #expect(job.disk == DiskInfo(totalKB: 500_000, freeKB: 120_000))
    }

    @Test func emptyScanEndsDone() async {
        let job = model(FakeEngine([.exited(0)]))
        await job.scan(["docker-list", "containers"])
        #expect(job.phase == .done)
        #expect(job.rows.isEmpty)
        #expect(job.failures.isEmpty)
    }

    @Test func nonZeroExitFails() async {
        let job = model(FakeEngine([.error("docker_not_ready", "Docker is not ready."), .exited(1)], [.exited(3)]))
        await job.scan(["docker-status"])
        #expect(job.phase == .failed("Docker is not ready."))
        #expect(job.failures == [EngineFailure(code: "docker_not_ready", message: "Docker is not ready.")])
        #expect(job.log.map(\.text) == ["Docker is not ready."])
        await job.scan(["docker-status"])
        #expect(job.phase == .failed("exit 3"))
        #expect(job.failures.isEmpty)
    }

    @Test func finderDeniedIsExposed() async {
        let denied = "Not authorized to send Apple events to Finder. (-1743)"
        let job = model(FakeEngine([.log(.info, "Emptying the Trash"), .error("finder_denied", denied), .exited(1)]))
        await job.run(["caches-clean", "trash"])
        #expect(job.hasFailure("finder_denied"))
        #expect(!job.hasFailure("docker_missing"))
        #expect(job.phase == .failed(denied))
    }

    @Test func runKeepsRowsClearsLog() async {
        let job = model(FakeEngine(
            [npmRow, .meta("total_safe", "2048"), .log(.warn, "scan note"), .exited(0)],
            [.log(.ok, "npm cache cleaned"), .plain("removed 12 files"), .stderr("npm WARN x"),
             .freed(2048), .disk(total: 100_000, free: 60_000), .exited(0)],
            [.exited(0)]))
        await job.scan(["caches-scan"])
        await job.run(["caches-clean", "npm"])
        #expect(job.phase == .done)
        #expect(job.rows.count == 1)
        #expect(job.meta["total_safe"] == "2048")
        #expect(job.log.map(\.text) == ["npm cache cleaned", "removed 12 files", "npm WARN x"])
        #expect(job.log.map(\.level) == [.ok, nil, nil])
        #expect(Set(job.log.map(\.id)).count == 3)
        #expect(job.freedKB == 2048)
        #expect(job.disk == DiskInfo(totalKB: 100_000, freeKB: 60_000))
        #expect(!job.lastRunWasDryRun)
        // The result of the last action outlives the rescan that follows it.
        await job.scan(["caches-scan"])
        #expect(job.rows.isEmpty && job.log.isEmpty)
        #expect(job.freedKB == 2048)
    }

    @Test func cancelOnlyWhileScanning() async {
        let engine = FakeEngine()
        let job = model(engine)

        let action = Task { await job.run(["caches-clean", "npm"]) }
        #expect(await settle { job.phase == .running })
        #expect(!job.canCancel && job.isBusy)
        job.cancel()
        #expect(engine.cancels == 0)
        #expect(job.phase == .running)
        engine.send(.log(.ok, "cleaned"), .exited(0), job: 0)
        await action.value
        #expect(job.phase == .done)

        let scan = Task { await job.scan(["caches-scan"]) }
        #expect(await settle { job.phase == .scanning })
        engine.send(.progress("Scanning caches", step: 1, total: 3), job: 1)
        #expect(await settle { job.progress != nil })
        #expect(job.progress == JobProgress(text: "Scanning caches", step: 1, total: 3))
        #expect(job.canCancel && job.isBusy)
        job.cancel()
        #expect(engine.cancels == 1)
        #expect(job.phase == .idle)
        #expect(job.progress == nil)
        engine.endAll()
        await scan.value
        #expect(job.phase == .idle)  // the exit 143 of the cancelled scan is ignored
        job.cancel()
        #expect(engine.cancels == 1)
    }

    @Test func passesCurrentOptions() async {
        var dryRun = true
        let engine = FakeEngine([.exited(0)], [.freed(0), .exited(0)], [.exited(0)])
        let job = JobModel(engine: engine, options: { EngineOptions(lang: "id", dryRun: dryRun) })
        await job.scan(["caches-scan"])
        await job.run(["caches-clean", "npm"])
        #expect(job.lastRunWasDryRun)
        #expect(job.freedKB == 0)
        dryRun = false
        await job.scan(["caches-scan"])
        #expect(engine.commands == [["caches-scan"], ["caches-clean", "npm"], ["caches-scan"]])
        #expect(engine.options == [EngineOptions(lang: "id", dryRun: true), EngineOptions(lang: "id", dryRun: true),
                                   EngineOptions(lang: "id", dryRun: false)])
        #expect(job.lastRunWasDryRun)  // still describes the last action, not the later scan
    }

    @Test func newScanCancelsScanInProgress() async {
        let engine = FakeEngine(exitOnCancel: false)
        let job = model(engine)
        let first = Task { await job.scan(["docker-list", "containers"]) }
        #expect(await settle { engine.commands.count == 1 })
        engine.send(.row("container", ["c1", "exited", "0B", "old", "img"]), job: 0)
        #expect(await settle { job.rows.count == 1 })

        let second = Task { await job.scan(["docker-list", "images"]) }
        #expect(await settle { engine.commands.count == 2 })
        #expect(engine.cancels == 1)
        #expect(job.rows.isEmpty)
        // Late output of the replaced scan never reaches the model.
        engine.send(.row("container", ["c2", "exited", "0B", "late", "img"]), .error("cancelled", "late"), .exited(143), job: 0)
        await first.value
        #expect(job.phase == .scanning)
        engine.send(.row("image", ["nginx:latest", "180MB", "2 weeks ago", "unused"]), .exited(0), job: 1)
        await second.value
        #expect(job.phase == .done)
        #expect(job.rows.map(\.kind) == ["image"])
        #expect(job.failures.isEmpty)
    }

    @Test func actionReplacesScanInProgress() async {
        let engine = FakeEngine()
        let job = model(engine)
        let scan = Task { await job.scan(["ram-scan"]) }
        #expect(await settle { job.phase == .scanning })
        let action = Task { await job.run(["ram-purge"]) }
        #expect(await settle { engine.commands.count == 2 })
        #expect(engine.cancels == 1)
        engine.send(.meta("cached_after", "1024"), job: 1)
        #expect(await settle { job.meta["cached_after"] != nil })
        #expect(job.phase == .running)  // the cancelled scan's exit 143 was ignored
        engine.endAll()
        await scan.value
        await action.value
        #expect(job.phase == .done)
        #expect(job.meta["cached_after"] == "1024")
    }

    @Test func nothingStartsWhileAnActionRuns() async {
        let engine = FakeEngine()
        let job = model(engine)
        let action = Task { await job.run(["updates-apply", "--list", "/tmp/l"]) }
        #expect(await settle { job.phase == .running })
        let ignored = Task {
            await job.scan(["updates-scan"])
            await job.run(["updates-apply", "--list", "/tmp/other"])
        }
        _ = await settle { engine.commands.count > 1 }  // room for a wrongly started job to show up
        #expect(engine.commands == [["updates-apply", "--list", "/tmp/l"]])
        #expect(job.phase == .running)
        engine.endAll()
        await ignored.value
        await action.value
        #expect(job.phase == .done)
    }

    @Test func cancellingTheCallerDoesNotStopTheJob() async {
        let engine = FakeEngine()
        let job = model(engine)
        let action = Task { await job.run(["uninstall", "/Applications/Foo.app", "--list", "/tmp/l"]) }
        #expect(await settle { job.phase == .running })
        action.cancel()  // e.g. the view that started it went away
        engine.send(.log(.ok, "Moved to Trash"), .exited(0), job: 0)
        await action.value
        #expect(engine.cancels == 0)
        #expect(job.phase == .done)
        #expect(job.log.map(\.text) == ["Moved to Trash"])
    }
}
