import Darwin
import Foundation
import Testing
@testable import MacCleanerCore

// The fixtures are small bash scripts run in place of mac-cleaner.command, with the same argv.
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
private func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

private let en = EngineOptions(lang: "en", dryRun: false)

private func collect(_ job: EngineJob) async -> [EngineEvent] {
    var events: [EngineEvent] = []
    for await event in job.events { events.append(event) }
    return events
}

private func run(_ script: String, _ command: [String] = ["x"], options: EngineOptions = en,
                 environment: [String: String] = [:]) async -> [EngineEvent] {
    await collect(ScriptEngine(scriptURL: fixture(script), extraEnvironment: environment).start(command, options: options))
}

/// Everything except stderr, whose order relative to stdout is not guaranteed.
private func stdoutEvents(_ events: [EngineEvent]) -> [EngineEvent] {
    events.filter { if case .stderr = $0 { false } else { true } }
}

private func stderrLines(_ events: [EngineEvent]) -> [String] {
    events.compactMap { if case .stderr(let text) = $0 { text } else { nil } }
}

private func exitCount(_ events: [EngineEvent]) -> Int {
    events.filter { if case .exited = $0 { true } else { false } }.count
}

@Suite(.timeLimit(.minutes(1)))
struct ScriptEngineTests {
    @Test func streamsEventsInOrderAndExit() async {
        let events = await run("echo.sh", ["disk"])
        #expect(stdoutEvents(events) == [.progress("A", step: nil, total: nil), .row("dir", ["10", "/x"]), .plain("plain line"), .exited(0)])
        #expect(stderrLines(events) == ["oops"])
    }

    @Test func passesOptionsBeforeEngine() async {
        let dry = await run("args.sh", ["caches-scan"], options: .init(lang: "id", dryRun: true))
        #expect(dry == [.plain("--lang id --dry-run --engine caches-scan"), .plain("5"), .exited(0)])
        let spaced = await run("args.sh", ["uninstall-plan", "/A/Foo Bar.app"])
        #expect(spaced == [.plain("--lang en --engine uninstall-plan /A/Foo Bar.app"), .plain("5"), .exited(0)])
    }

    @Test func exitCodeIsDelivered() async {
        let events = await run("exit3.sh")
        #expect(events == [.exited(3)])
    }

    @Test func exitedWaitsForOutputThatOutlivesTheScript() async {
        let events = await run("late.sh")
        #expect(stdoutEvents(events) == [.plain("late"), .exited(4)])
        #expect(stderrLines(events) == ["late-err"])
    }

    @Test func partialLastLineIsDelivered() async {
        let events = await run("partial.sh")
        #expect(stdoutEvents(events) == [.plain("a"), .plain("b"), .exited(0)])
        #expect(stderrLines(events) == ["c"])
    }

    @Test func stripsOneTrailingCarriageReturn() async {
        let events = await run("crlf.sh")
        #expect(stdoutEvents(events) == [.plain("one"), .meta("k", "v"), .plain("three\r"), .plain("10%\r20%"), .exited(0)])
        #expect(stderrLines(events) == ["warn"])
    }

    @Test func passesExtraEnvironment() async {
        let events = await run("env.sh", environment: ["FOO": "bar baz", "HOME": "/tmp/fake-home"])
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        #expect(events == [.plain("bar baz"), .plain("/tmp/fake-home"), .plain(path), .exited(0)])
    }

    @Test func environmentAddsAppPathOnlyForAppBundles() {
        let inherited = ["PATH": "/usr/bin", "HOME": "/Users/x"]
        let app = ScriptEngine.environment(inherited: inherited, bundlePath: "/Applications/Mac Cleaner.app", extra: [:])
        #expect(app == ["PATH": "/usr/bin", "HOME": "/Users/x", "MAC_CLEANER_APP": "/Applications/Mac Cleaner.app"])
        let tool = ScriptEngine.environment(inherited: inherited, bundlePath: "/usr/local/bin", extra: ["HOME": "/tmp/h"])
        #expect(tool == ["PATH": "/usr/bin", "HOME": "/tmp/h"])
    }

    @Test func cancelKillsProcessGroup() async throws {
        let job = ScriptEngine(scriptURL: fixture("sleeper.sh")).start(["x"], options: en)
        var grandchild: pid_t?
        var cancelledAt = ContinuousClock.now
        var events: [EngineEvent] = []
        for await event in job.events {
            events.append(event)
            if case .meta("pid", let value) = event {
                grandchild = pid_t(value)
                cancelledAt = .now
                job.cancel()
            }
        }
        #expect(events.last == .exited(143))
        #expect(exitCount(events) == 1)
        // `sleep 30` holds stdout open, so the stream only ends this soon if the whole group died.
        #expect(ContinuousClock.now - cancelledAt < .seconds(5))
        // The orphaned `sleep` is reaped by launchd, so allow it a moment as a zombie.
        let pid = try #require(grandchild)
        let deadline = ContinuousClock.now + .seconds(2)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func cancelAfterExitIsNoop() async throws {
        let job = ScriptEngine(scriptURL: fixture("pid.sh")).start(["x"], options: en)
        let events = await collect(job)
        #expect(events.last == .exited(0))
        // The child was reaped (no zombie), so its pid may already belong to someone else.
        guard case .meta("pid", let value) = events.first, let pid = pid_t(value) else {
            Issue.record("no pid in \(events)")
            return
        }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        job.cancel()
        job.cancel()
        #expect(await collect(job).isEmpty)
    }

    @Test func missingScriptFailsCleanly() async {
        let missing = fixture("does-not-exist.sh")
        let events = await collect(ScriptEngine(scriptURL: missing).start(["env"], options: en))
        #expect(events == [.error("not_found", missing.path), .exited(127)])
        let directory = await collect(ScriptEngine(scriptURL: fixtures).start(["env"], options: en))
        #expect(directory == [.error("not_found", fixtures.path), .exited(127)])
    }

    @Test func largeOutputOnBothPipes() async {
        let events = await run("flood.sh")
        let rows = events.compactMap { if case .row("dir", let fields) = $0 { Int(fields[0]) } else { nil } }
        #expect(rows == Array(1...5000))
        #expect(stderrLines(events) == (1...5000).map { "stderr line \($0) with padding to fill the pipe buffer quickly" })
        #expect(events.count == 10_001)
        #expect(events.last == .exited(0))
    }
}

@Test func lineSplitterHandlesChunkBoundaries() {
    var splitter = LineSplitter()
    let bytes = Array("ab\r\nc\u{e9}d\n\ne".utf8)
    var lines: [String] = []
    for byte in bytes { lines += splitter.append([byte]) }  // splits "é" across two chunks
    #expect(lines == ["ab", "c\u{e9}d", ""])
    #expect(splitter.finish() == "e")
    #expect(splitter.finish() == nil)
}

@Suite(.timeLimit(.minutes(1)))
struct DemoEngineTests {
    @Test func demoReplaysFixture() async {
        let events = await collect(DemoEngine(fixtures: fixtures, lineDelay: .milliseconds(1)).start(["caches-scan"], options: en))
        #expect(events == [
            .progress("Scanning caches", step: 1, total: 2),
            .row("cache", ["npm", "2048", "safe", "npm / npx cache"]),
            .row("cache", ["trash", "-1", "permanent", "Trash"]),
            .meta("total_safe", "2048"),
            .meta("total_heavy", "0"),
            .exited(0),
        ])
    }

    @Test func demoMissingFixture() async {
        let events = await collect(DemoEngine(fixtures: fixtures).start(["docker-list", "images"], options: en))
        #expect(events == [.error("not_found", "docker-list-images"), .exited(1)])
    }

    @Test func demoCancelEndsStream() async {
        let job = DemoEngine(fixtures: fixtures, lineDelay: .seconds(30)).start(["caches-scan"], options: en)
        job.cancel()
        #expect(await collect(job) == [.exited(143)])
    }
}

@Test func demoNames() {
    #expect(EngineLocator.demoName(["caches-scan"]) == "caches-scan")
    #expect(EngineLocator.demoName(["docker-list", "images"]) == "docker-list-images")
    #expect(EngineLocator.demoName(["docker-rm", "volumes", "--list", "/tmp/l"]) == "docker-rm-volumes")
    #expect(EngineLocator.demoName(["docker-prune", "safe"]) == "docker-prune-safe")
    #expect(EngineLocator.demoName(["uninstall-plan", "/A/Foo.app"]) == "uninstall-plan")
}

@Test func scriptLocation() {
    let override = EngineLocator.scriptURL(environment: ["MAC_CLEANER_SCRIPT": "/tmp/engine.command"], bundle: .main)
    #expect(override == URL(fileURLWithPath: "/tmp/engine.command"))
    // The test runner's bundle has no mac-cleaner.command.
    #expect(EngineLocator.scriptURL(environment: [:], bundle: .main) == nil)
}
