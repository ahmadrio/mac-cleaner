import Foundation

/// Where the uninstall sheet stands.
public enum UninstallStage: Equatable, Sendable {
    /// The plan is on screen and can be acted on (also after a dry run, which moved nothing).
    case plan
    /// A real uninstall went through: the app and the ticked leftovers are in the Trash.
    case moved
    /// A real uninstall reached the engine but failed: some items may have moved, others not. The sheet offers
    /// nothing more to move; opening it again reads a fresh plan.
    case finishedWithProblems

    /// Only the plan can be acted on: after a real run its list is stale.
    public var canMove: Bool { self == .plan }
}

/// What the uninstall sheet does once `uninstall` ended, kept out of the view so it can be tested (like
/// `UpdateLogic.shouldRescan`).
public enum UninstallFlow {
    public struct AfterRun: Equatable, Sendable {
        public let stage: UninstallStage
        /// Refresh the disk bar and the list behind the sheet: something may have moved.
        public let refresh: Bool
        /// Read the plan again, keeping the log, so the sheet shows what is still on the Mac.
        public let reloadPlan: Bool

        public init(stage: UninstallStage, refresh: Bool, reloadPlan: Bool) {
            self.stage = stage; self.refresh = refresh; self.reloadPlan = reloadPlan
        }
    }

    /// `reachedEngine` is false when the list file couldn't be written; `succeeded` is whether the job ended `.done`;
    /// `appStillExists` whether the app bundle is still on disk (the engine plans only for an installed app).
    public static func afterRun(reachedEngine: Bool, dryRun: Bool, succeeded: Bool, appStillExists: Bool) -> AfterRun {
        guard reachedEngine, !dryRun else { return AfterRun(stage: .plan, refresh: false, reloadPlan: false) }
        if succeeded { return AfterRun(stage: .moved, refresh: true, reloadPlan: false) }
        return AfterRun(stage: .finishedWithProblems, refresh: true, reloadPlan: appStillExists)
    }
}
