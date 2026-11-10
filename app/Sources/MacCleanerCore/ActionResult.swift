import Combine
import Foundation

/// How a failure reads on screen. Views map it to text.
public enum FailureNote: Equatable, Sendable {
    /// The engine's own message.
    case message(String)
    /// `not_found`: the script or a demo fixture is missing, and the message is only its path or name.
    case notFound(String)
    /// `not_allowed`: the message is only the refused path or line.
    case notAllowed(String)
    /// The job failed without an error record (a step failed and the script exited non-zero): the log has the details.
    case seeLog

    /// The note for a job that ended with these failures. nil for those a screen explains another way:
    /// `finder_denied` (the Automation callout) and `cancelled` (the user dismissed a password dialog, not an error).
    public init?(failures: [EngineFailure]) {
        if failures.contains(where: { $0.code == "finder_denied" || $0.code == "cancelled" }) { return nil }
        guard let last = failures.last else { self = .seeLog; return }
        switch last.code {
        case "not_found": self = .notFound(last.message)
        case "not_allowed": self = .notAllowed(last.message)
        default: self = .message(last.message)
        }
    }
}

/// What a screen's result banner says about the job's last action. Views map it to text.
public enum ActionResult: Equatable, Sendable {
    /// A dry run that went through: nothing was deleted.
    case dryRun
    /// Done. `kb` is the space freed (0 when nothing measurable was freed), `freeKB` the free space after it if known.
    case freed(kb: Int, freeKB: Int?)
    /// The user dismissed a password dialog.
    case cancelled
    /// At least one step failed. `note` says why (nil when a callout explains it, e.g. `finder_denied`); `freedKB` is
    /// the space freed anyway, if any. Never shown as a success, even when something was freed.
    case failed(note: FailureNote?, freedKB: Int?)
}

extension JobModel {
    /// How the current failure reads, while the job is `.failed` (scan or action); nil otherwise.
    public var failureNote: FailureNote? {
        guard case .failed = phase else { return nil }
        return FailureNote(failures: failures)
    }

    /// How the last action's failure reads; nil unless it failed. Unlike `failureNote` it outlives the rescan after the action.
    public var actionFailureNote: FailureNote? {
        actionFailed ? FailureNote(failures: actionFailures) : nil
    }

    /// The result banner for the last action, from its end until a plain scan or the next action (the rescan after
    /// it keeps it). nil before any action, while one runs, and after an action that reported nothing (`@@freed`) and
    /// did not fail: such a screen says its result its own way.
    public var actionResult: ActionResult? {
        guard hasActed, phase != .running else { return nil }
        if actionHasFailure("cancelled") { return .cancelled }
        if actionFailed {
            let freed = freedKB.flatMap { $0 > 0 && !lastRunWasDryRun ? $0 : nil }
            return .failed(note: actionFailureNote, freedKB: freed)
        }
        guard let freed = freedKB else { return nil }
        if lastRunWasDryRun { return .dryRun }
        return .freed(kb: max(freed, 0), freeKB: disk?.freeKB)
    }
}

/// Knows whether any job runs an action, so only one runs at a time across screens (two Homebrew runs, say, would
/// fight over its lock) and the language stays put meanwhile. Jobs made with a tracker report to it; scans don't count.
@MainActor
public final class ActionTracker: ObservableObject {
    @Published public private(set) var isActive = false
    private var running: Set<ObjectIdentifier> = []

    public init() {}

    func update(_ job: JobModel) {
        if job.phase == .running { running.insert(ObjectIdentifier(job)) } else { running.remove(ObjectIdentifier(job)) }
        if isActive == running.isEmpty { isActive = !running.isEmpty }
    }
}
