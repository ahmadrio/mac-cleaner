import Darwin
import Foundation

public struct EngineOptions: Sendable, Equatable {
    public var lang: String
    public var dryRun: Bool

    public init(lang: String, dryRun: Bool) { self.lang = lang; self.dryRun = dryRun }
}

public protocol EngineClient: Sendable {
    func start(_ command: [String], options: EngineOptions) -> EngineJob
}

/// One engine run. `events` always ends with exactly one `.exited(code)`.
///
/// Only `cancel()` stops the run. Dropping `events`, or cancelling the task that iterates it, ends that
/// iteration (and the stream) but not the script, which runs on to its end unobserved. So whoever owns the
/// job (`JobModel`) keeps it and calls `cancel()` itself.
public final class EngineJob: Sendable {
    public let events: AsyncStream<EngineEvent>
    private let onCancel: @Sendable () -> Void

    public init(events: AsyncStream<EngineEvent>, onCancel: @escaping @Sendable () -> Void) {
        self.events = events
        self.onCancel = onCancel
    }

    /// Stops the run (for a script: SIGTERM to its whole process group). A no-op once it has exited.
    public func cancel() { onCancel() }

    /// A job that has already ended with `events`.
    static func completed(_ events: [EngineEvent]) -> EngineJob {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
        events.forEach { continuation.yield($0) }
        continuation.finish()
        return EngineJob(events: stream, onCancel: {})
    }
}

/// Runs `/bin/bash <script> --lang <l> [--dry-run] --engine <command…>`.
public final class ScriptEngine: EngineClient {
    private let scriptURL: URL
    private let extraEnvironment: [String: String]

    public init(scriptURL: URL, extraEnvironment: [String: String] = [:]) {
        self.scriptURL = scriptURL
        self.extraEnvironment = extraEnvironment
    }

    public func start(_ command: [String], options: EngineOptions) -> EngineJob {
        let path = scriptURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path)
        else { return .completed([.error("not_found", path), .exited(127)]) }

        var arguments = [path, "--lang", options.lang]
        if options.dryRun { arguments.append("--dry-run") }
        arguments += ["--engine"] + command
        let environment = Self.environment(inherited: ProcessInfo.processInfo.environment,
                                           bundlePath: Bundle.main.bundlePath, extra: extraEnvironment)
        return ScriptProcess.launch(arguments: arguments, environment: environment)
    }

    static func environment(inherited: [String: String], bundlePath: String, extra: [String: String]) -> [String: String] {
        var environment = inherited
        if bundlePath.hasSuffix(".app") { environment["MAC_CLEANER_APP"] = bundlePath }
        environment.merge(extra) { _, new in new }
        return environment
    }
}

/// A spawned `/bin/bash` that leads its own process group. Two reader threads (stdout, stderr) and one
/// waiter thread feed the stream; the waiter yields `.exited` after the child is reaped and both pipes hit
/// EOF, or `eofGrace` after the reap if a leftover descendant still holds a pipe open.
private final class ScriptProcess: @unchecked Sendable {
    /// How long to wait for pipe EOF after the reap; a daemon holding stdout must not keep the job open.
    static let eofGrace: DispatchTimeInterval = .seconds(2)

    private let pid: pid_t
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let stop: (read: Int32, write: Int32)  // closing `write` wakes the readers and ends them
    private let readers = DispatchGroup()
    private let lock = NSLock()
    private var reaped = false  // guarded by `lock`; once true the pid may belong to another process

    private init(pid: pid_t, continuation: AsyncStream<EngineEvent>.Continuation, stop: (read: Int32, write: Int32)) {
        self.pid = pid
        self.continuation = continuation
        self.stop = stop
    }

    static func launch(arguments: [String], environment: [String: String]) -> EngineJob {
        var fds: [Int32] = []  // stdout, stderr and stop pipes: read end, write end
        for _ in 0..<3 {
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else { let code = errno; fds.forEach { close($0) }; return spawnFailed(code) }
            fds += ends
        }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let out = [fds[0], fds[1]], err = [fds[2], fds[3]], stop = (read: fds[4], write: fds[5])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)

        // Own process group (pgid = pid) so cancel() reaches every descendant; default signal handling
        // and an empty mask so SIGTERM works even if the app ignores or blocks it; and no inherited fds
        // besides 0–2, so another job's pipe can never be held open by this child.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
                                                  | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        var signals = sigset_t()
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attr, &signals)
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attr, &signals)

        let argv = (["/bin/bash"] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/bash", &actions, &attr, argv, envp)
        close(out[1])
        close(err[1])
        guard rc == 0 else { [out[0], err[0], stop.read, stop.write].forEach { close($0) }; return spawnFailed(rc) }

        let (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
        let process = ScriptProcess(pid: pid, continuation: continuation, stop: stop)
        process.read(out[0]) { ProtocolParser.parse($0) }
        process.read(err[0]) { .stderr($0) }
        process.waitForExit()
        return EngineJob(events: events, onCancel: { process.cancel() })
    }

    private static func spawnFailed(_ code: Int32) -> EngineJob {
        .completed([.error("not_found", "/bin/bash: " + String(cString: strerror(code))), .exited(127)])
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if !reaped { kill(-pid, SIGTERM) }
    }

    /// Reads `fd` on its own thread until EOF or a stop, yielding one event per line, then closes it.
    private func read(_ fd: Int32, _ event: @escaping @Sendable (String) -> EngineEvent) {
        readers.enter()
        Thread.detachNewThread { [self] in
            var splitter = LineSplitter()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            var watched = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: stop.read, events: Int16(POLLIN), revents: 0)]
            while true {
                let ready = poll(&watched, 2, -1)
                if ready < 0, errno == EINTR { continue }
                if ready < 0 || watched[1].revents != 0 { break }  // stopped: the EOF grace ran out
                guard watched[0].revents != 0 else { continue }
                let count = Darwin.read(fd, &chunk, chunk.count)
                if count > 0 {
                    splitter.append(chunk[..<count]).forEach { continuation.yield(event($0)) }
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break  // EOF (or a read error, which ends the pipe the same way)
                }
            }
            if let last = splitter.finish() { continuation.yield(event(last)) }
            close(fd)
            readers.leave()
        }
    }

    private func waitForExit() {
        Thread.detachNewThread { [self] in
            // Wait without reaping: while the child is a zombie its pid (and pgid) cannot be reused,
            // so cancel() may still signal safely. Reap under the lock so cancel() never races it.
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            var status: Int32 = 0
            lock.lock()
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            reaped = true
            lock.unlock()
            // Give leftover output a moment, then stop readers still waiting for EOF. They yield
            // everything already read (a partial line too) before leaving the group.
            _ = readers.wait(timeout: .now() + Self.eofGrace)
            close(stop.write)
            readers.wait()
            close(stop.read)
            continuation.yield(.exited(result == pid ? Self.exitCode(status) : -1))
            continuation.finish()
        }
    }

    /// The shell convention: the exit status, or 128 + signal for a signal death (143 for SIGTERM).
    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}

/// Splits bytes into UTF-8 lines on "\n" and drops one trailing "\r" per line (CRLF tool output).
struct LineSplitter {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: some Collection<UInt8>) -> [String] {
        var searchFrom = pending.count  // `pending` never holds a "\n"
        pending.append(contentsOf: bytes)
        var lines: [String] = []
        var start = 0
        while let newline = pending[searchFrom...].firstIndex(of: 0x0A) {
            lines.append(Self.text(pending[start..<newline]))
            start = newline + 1
            searchFrom = start
        }
        pending.removeFirst(start)
        return lines
    }

    /// The partial last line, if any.
    mutating func finish() -> String? {
        defer { pending = [] }
        return pending.isEmpty ? nil : Self.text(pending[...])
    }

    private static func text(_ line: ArraySlice<UInt8>) -> String {
        String(decoding: line.last == 0x0D ? line.dropLast() : line, as: UTF8.self)
    }
}

/// Replays `<fixtures>/<demoName>.txt` line by line instead of running the script.
public final class DemoEngine: EngineClient {
    private let fixtures: URL
    private let lineDelay: Duration

    public init(fixtures: URL, lineDelay: Duration = .milliseconds(15)) {
        self.fixtures = fixtures
        self.lineDelay = lineDelay
    }

    public func start(_ command: [String], options: EngineOptions) -> EngineJob {
        let name = EngineLocator.demoName(command)
        let file = fixtures.appendingPathComponent(name + ".txt")
        let delay = lineDelay
        let (events, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
        let replay = Task {
            guard let data = try? Data(contentsOf: file) else {
                continuation.yield(.error("not_found", name))
                continuation.yield(.exited(1))
                continuation.finish()
                return
            }
            var splitter = LineSplitter()
            let lines = splitter.append(data) + [splitter.finish()].compactMap { $0 }
            var cancelled = false
            for line in lines {
                do { try await Task.sleep(for: delay) } catch { cancelled = true; break }
                continuation.yield(ProtocolParser.parse(line))
            }
            continuation.yield(.exited(cancelled ? 128 + SIGTERM : 0))
            continuation.finish()
        }
        return EngineJob(events: events, onCancel: { replay.cancel() })
    }
}

public enum EngineLocator {
    /// `$MAC_CLEANER_SCRIPT` (dev override), else the bundled `mac-cleaner.command`.
    public static func scriptURL() -> URL? {
        scriptURL(environment: ProcessInfo.processInfo.environment, bundle: .main)
    }

    static func scriptURL(environment: [String: String], bundle: Bundle) -> URL? {
        if let path = environment["MAC_CLEANER_SCRIPT"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return bundle.url(forResource: "mac-cleaner", withExtension: "command")
    }

    public static var isDemo: Bool { ProcessInfo.processInfo.environment["MAC_CLEANER_DEMO"] == "1" }

    /// The fixture name for a command: its name, plus the subcommand for docker-list/rm/prune.
    public static func demoName(_ command: [String]) -> String {
        guard let name = command.first else { return "" }
        if ["docker-list", "docker-rm", "docker-prune"].contains(name), command.count > 1 { return "\(name)-\(command[1])" }
        return name
    }
}
