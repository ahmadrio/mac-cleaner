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
///
/// The last action's result (its log, `freedKB`, `disk`, `actionFailures`, `outcome`) stays until a plain `scan` or
/// the next action. The rescan right after an action (`scan(_:keepLog: true)`) keeps it, so the screen can still show
/// it. It lives here, not in a view, so it survives switching screens and languages.
@MainActor
public final class JobModel: ObservableObject {
    public enum Phase: Equatable { case idle, scanning, running, done, failed(String) }

    @Published public private(set) var phase: Phase = .idle {
        didSet { if (oldValue == .running) != (phase == .running) { tracker?.update(self) } }
    }
    @Published public private(set) var progress: JobProgress?
    @Published public private(set) var rows: [EngineRow] = []
    @Published public private(set) var meta: [String: String] = [:]
    @Published public private(set) var log: [LogLine] = []
    /// The failures of the current (or latest) job, scan or action.
    @Published public private(set) var failures: [EngineFailure] = []
    /// The last action's `@@freed` (0 in dry-run). The rescan after the action keeps it.
    @Published public private(set) var freedKB: Int?
    /// The latest `@@disk` (actions send it after `@@freed`; so does the `disk` command). Kept like `freedKB`.
    @Published public private(set) var disk: DiskInfo?
    /// Whether the last action ran with `--dry-run` (the toggle may have changed since).
    @Published public private(set) var lastRunWasDryRun = false
    /// True while the log and the result belong to an action: set when `run`/`runLocal` start, kept by the rescan
    /// after it, cleared by a plain `scan`. A plain scan's own lines (e.g. "Measuring caches…") are not worth a log panel.
    @Published public private(set) var hasActed = false
    /// The failures the last action ended with (empty while it runs). Unlike `failures`, the rescan after the action
    /// keeps them, so a permission callout or a failure banner outlives that rescan.
    @Published public private(set) var actionFailures: [EngineFailure] = []
    /// True when the last action exited non-zero. Kept and cleared like `actionFailures`.
    @Published public private(set) var actionFailed = false
    /// What the screen made of its last action, as a value of the screen's own outcome type, for its result banner.
    /// Kept through the rescan after the action; cleared by a plain `scan` or the next action. Screens set it.
    @Published public var outcome: AnyHashable?
    /// The command of the latest scan (a cancelled one too), e.g. to rescan with the same arguments. nil before any scan.
    @Published public private(set) var lastScan: [String]?

    private var lastStartWasScan = false

    private let engine: EngineClient
    private let options: @MainActor () -> EngineOptions
    private let tracker: ActionTracker?
    private var job: EngineJob?   // the current job, kept so that cancel() can stop a scan
    private var generation = 0    // bumped by every start and cancel; events of older jobs are ignored
    private var nextLogID = 0

    /// `options` is read at each start, so every job runs with the current language and dry-run setting.
    /// `tracker` learns when this job's actions start and end (one action at a time across screens).
    public init(engine: EngineClient, options: @escaping @MainActor () -> EngineOptions, tracker: ActionTracker? = nil) {
        self.engine = engine
        self.options = options
        self.tracker = tracker
    }

    public var canCancel: Bool { phase == .scanning }
    public var isBusy: Bool { phase == .scanning || phase == .running }
    /// True when the latest job was a scan and it failed (an action that failed does not count).
    public var scanFailed: Bool {
        if case .failed = phase { return lastStartWasScan }
        return false
    }

    /// Clears rows, meta and failures, then runs `command`: `.scanning` → `.done` | `.failed`.
    /// A plain scan also clears the last action's result (log, freed space, failures, outcome). `keepLog` keeps it,
    /// for the rescan right after an action, whose result should stay on screen.
    /// A scan that fails drops its rows and meta again (the list would be incomplete); log and failures stay.
    public func scan(_ command: [String], keepLog: Bool = false) async {
        guard phase != .running else { return }
        rows = []
        meta = [:]
        failures = []
        if !keepLog {
            log = []
            clearLastAction()
            hasActed = false
        }
        lastScan = command
        await start(command, as: .scanning, options: options())
    }

    /// Keeps rows and meta (unless it replaces a scan in progress, which drops them), clears failures and the last
    /// action's result, then runs `command`: `.running` → `.done` | `.failed`. The log is cleared too, unless `keepLog`
    /// (for an action that continues in-app work, e.g. quitting apps first, whose lines should stay).
    public func run(_ command: [String], keepLog: Bool = false) async {
        guard phase != .running else { return }
        let options = options()
        if phase == .scanning {  // this action replaces the scan: drop its unfinished list
            rows = []
            meta = [:]
        }
        beginAction(options, keepLog: keepLog)
        await start(command, as: .running, options: options)
    }

    /// Runs in-app work that is not an engine command (e.g. quitting apps) as an action, so `isBusy` covers it and
    /// nothing else starts meanwhile. Like `run`: `.running` → `.done`, rows and meta stay, the log (unless `keepLog`),
    /// failures and the last result are cleared (a scan in progress is replaced and its unfinished list dropped).
    /// `work` reports through `note`.
    public func runLocal(keepLog: Bool = false, _ work: @MainActor (JobModel) async -> Void) async {
        guard phase != .running else { return }
        let options = options()
        if phase == .scanning {
            generation += 1
            job?.cancel()
            job = nil
            rows = []
            meta = [:]
            progress = nil
        }
        beginAction(options, keepLog: keepLog)
        lastStartWasScan = false
        phase = .running
        await work(self)
        phase = .done
    }

    private func beginAction(_ options: EngineOptions, keepLog: Bool) {
        if !keepLog { log = [] }
        failures = []
        clearLastAction()
        hasActed = true
        lastRunWasDryRun = options.dryRun
    }

    private func clearLastAction() {
        freedKB = nil
        disk = nil
        actionFailures = []
        actionFailed = false
        outcome = nil
    }

    /// Adds a line to the log, for in-app work that has no engine output.
    public func note(_ level: LogLevel, _ text: String) { appendLog(level, text) }

    /// Stops a scan (SIGTERM to its process group), drops its unfinished rows and meta, and returns to `.idle`. A no-op unless `.scanning`.
    public func cancel() {
        guard phase == .scanning else { return }
        generation += 1
        job?.cancel()
        job = nil
        rows = []  // an unfinished scan must not leave a partial list that looks complete
        meta = [:]
        progress = nil
        phase = .idle
    }

    /// The rows of one kind that `make` accepts, e.g. `rows("cache", as: CacheItem.init(fields:))`.
    public func rows<T>(_ kind: String, as make: ([String]) -> T?) -> [T] {
        rows.filter { $0.kind == kind }.compactMap { make($0.fields) }
    }

    public func hasFailure(_ code: String) -> Bool { failures.contains { $0.code == code } }

    /// Whether the last action ended with this failure code; true through the rescan that follows it.
    public func actionHasFailure(_ code: String) -> Bool { actionFailures.contains { $0.code == code } }

    /// The scan in progress was cancelled: the job is back at `.idle` after a scan had started.
    public var scanWasCancelled: Bool { phase == .idle && lastScan != nil }

    /// Whether a screen shows its log panel: only for an action (while it runs and until a plain scan) or to explain
    /// a failed scan. A plain scan's own lines would only push the list down.
    public var showsLog: Bool { !log.isEmpty && (hasActed || scanFailed) }

    private func start(_ command: [String], as newPhase: Phase, options: EngineOptions) async {
        job?.cancel()  // only a scan can be in progress here
        generation += 1
        let token = generation
        lastStartWasScan = newPhase == .scanning
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
        if lastStartWasScan, code != 0 {  // a failed scan's list is incomplete: never leave it to act on
            rows = []
            meta = [:]
        }
        if !lastStartWasScan {
            actionFailures = failures
            actionFailed = code != 0
        }
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
