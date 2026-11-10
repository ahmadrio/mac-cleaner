import Combine
import Foundation

/// One `@@row` record: its kind and the fields after it. Typed views come from `JobModel.rows(_:as:)`.
public struct EngineRow: Equatable, Sendable {
    public let kind: String
    public let fields: [String]
}

/// One `@@error` record.
public struct EngineFailure: Equatable, Sendable {
    public let code: String
    public let message: String
}

/// The latest `@@progress` record; `step`/`total` are set for "[step/total] text" progress.
public struct JobProgress: Equatable, Sendable {
    public let text: String
    public let step: Int?
    public let total: Int?
}

/// One line for the log panel. `level` is nil for raw tool output and stderr.
public struct LogLine: Equatable, Identifiable, Sendable {
    public let id: Int
    public let level: LogLevel?
    public let text: String
}

/// The engine work of one screen: a scan or an action, and what it streams back.
///
/// One thing runs at a time:
/// - a new `scan` or `run` cancels a scan in progress (the latest wins; the old scan's remaining events are ignored);
/// - while an action runs, `scan` and `run` return at once without starting anything;
/// - only scans can be cancelled. Actions always run to the end.
///
/// The model owns its job, not the caller: cancelling the task that awaits `scan`/`run` neither stops the
/// job nor cuts its events short, and both still return only once the job has ended.
@MainActor
public final class JobModel: ObservableObject {
    public enum Phase: Equatable { case idle, scanning, running, done, failed(String) }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var progress: JobProgress?
    @Published public private(set) var rows: [EngineRow] = []
    @Published public private(set) var meta: [String: String] = [:]
    @Published public private(set) var log: [LogLine] = []
    @Published public private(set) var failures: [EngineFailure] = []
    /// The last action's `@@freed` (0 in dry-run). A scan keeps it, so it survives the rescan after an action.
    @Published public private(set) var freedKB: Int?
    /// The latest `@@disk` (actions send it after `@@freed`; so does the `disk` command). A scan keeps it, like `freedKB`.
    @Published public private(set) var disk: DiskInfo?
    /// Whether the last action ran with `--dry-run` (the toggle may have changed since).
    @Published public private(set) var lastRunWasDryRun = false

    private let engine: EngineClient
    private let options: @MainActor () -> EngineOptions
    private var job: EngineJob?   // the current job, kept so that cancel() can stop a scan
    private var generation = 0    // bumped by every start and cancel; events of older jobs are ignored
    private var nextLogID = 0

    /// `options` is read at each start, so every job runs with the current language and dry-run setting.
    public init(engine: EngineClient, options: @escaping @MainActor () -> EngineOptions) {
        self.engine = engine
        self.options = options
    }

    public var canCancel: Bool { phase == .scanning }
    public var isBusy: Bool { phase == .scanning || phase == .running }

    /// Clears rows, meta, log and failures, then runs `command`: `.scanning` → `.done` | `.failed`.
    public func scan(_ command: [String]) async {
        guard phase != .running else { return }
        rows = []
        meta = [:]
        log = []
        failures = []
        await start(command, as: .scanning, options: options())
    }

    /// Keeps rows and meta, clears log, failures and the last result, then runs `command`: `.running` → `.done` | `.failed`.
    public func run(_ command: [String]) async {
        guard phase != .running else { return }
        let options = options()
        log = []
        failures = []
        freedKB = nil
        disk = nil
        lastRunWasDryRun = options.dryRun
        await start(command, as: .running, options: options)
    }

    /// Stops a scan (SIGTERM to its process group) and returns to `.idle`. A no-op unless `.scanning`.
    public func cancel() {
        guard phase == .scanning else { return }
        generation += 1
        job?.cancel()
        job = nil
        progress = nil
        phase = .idle
    }

    /// The rows of one kind that `make` accepts, e.g. `rows("cache", as: CacheItem.init(fields:))`.
    public func rows<T>(_ kind: String, as make: ([String]) -> T?) -> [T] {
        rows.filter { $0.kind == kind }.compactMap { make($0.fields) }
    }

    public func hasFailure(_ code: String) -> Bool { failures.contains { $0.code == code } }

    private func start(_ command: [String], as newPhase: Phase, options: EngineOptions) async {
        job?.cancel()  // only a scan can be in progress here
        generation += 1
        let token = generation
        progress = nil
        phase = newPhase
        let job = engine.start(command, options: options)
        self.job = job
        // An unstructured task, so a cancelled caller can't end the event stream early (that would drop
        // `.exited` and leave the phase stuck while the script runs on).
        await Task { await self.consume(job, token: token) }.value
    }

    private func consume(_ job: EngineJob, token: Int) async {
        var code: Int32 = -1  // stays -1 only if a stream ever ended without `.exited`
        for await event in job.events where token == generation {
            if case .exited(let exitCode) = event { code = exitCode } else { apply(event) }
        }
        guard token == generation else { return }  // cancelled or replaced: the newer state stands
        self.job = nil
        progress = nil
        phase = code == 0 ? .done : .failed(failures.last?.message ?? "exit \(code)")
    }

    private func apply(_ event: EngineEvent) {
        switch event {
        case let .progress(text, step, total): progress = JobProgress(text: text, step: step, total: total)
        case let .log(level, text): appendLog(level, text)
        case let .meta(key, value): meta[key] = value
        case let .row(kind, fields): rows.append(EngineRow(kind: kind, fields: fields))
        case let .freed(kb): freedKB = kb
        case let .disk(total, free): disk = DiskInfo(totalKB: total, freeKB: free)
        case let .error(code, message):
            failures.append(EngineFailure(code: code, message: message))
            appendLog(.err, message)
        case let .plain(text), let .stderr(text): appendLog(nil, text)
        case .exited: break
        }
    }

    private func appendLog(_ level: LogLevel?, _ text: String) {
        log.append(LogLine(id: nextLogID, level: level, text: text))
        nextLogID += 1
    }
}
