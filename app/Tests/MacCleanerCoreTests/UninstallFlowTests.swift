import Testing
@testable import MacCleanerCore

/// What the uninstall sheet does after `uninstall` ended: a partly failed run must not leave a stale plan to act on.
@Suite struct UninstallFlowTests {
    @Test func aDryRunKeepsThePlanActionable() {
        for succeeded in [true, false] {
            let next = UninstallFlow.afterRun(reachedEngine: true, dryRun: true, succeeded: succeeded, appStillExists: true)
            #expect(next == UninstallFlow.AfterRun(stage: .plan, refresh: false, reloadPlan: false))
        }
    }

    @Test func nothingHappensWhenTheEngineWasNeverReached() {
        // e.g. the list file couldn't be written: nothing moved, so the plan is still right.
        let next = UninstallFlow.afterRun(reachedEngine: false, dryRun: false, succeeded: false, appStillExists: true)
        #expect(next == UninstallFlow.AfterRun(stage: .plan, refresh: false, reloadPlan: false))
    }

    @Test func aRealUninstallThatWentThroughIsDone() {
        let next = UninstallFlow.afterRun(reachedEngine: true, dryRun: false, succeeded: true, appStillExists: false)
        #expect(next == UninstallFlow.AfterRun(stage: .moved, refresh: true, reloadPlan: false))
    }

    @Test func aPartlyFailedUninstallFinishesWithProblemsAndShowsWhatIsLeft() {
        // e.g. a root-owned app (GarageBand) stays while its leftovers moved: refresh, never offer the stale plan again.
        let next = UninstallFlow.afterRun(reachedEngine: true, dryRun: false, succeeded: false, appStillExists: true)
        #expect(next == UninstallFlow.AfterRun(stage: .finishedWithProblems, refresh: true, reloadPlan: true))
    }

    @Test func aFailedUninstallWhoseAppMovedCannotReadThePlanAgain() {
        // The engine only plans for an installed app, so a reload would fail.
        let next = UninstallFlow.afterRun(reachedEngine: true, dryRun: false, succeeded: false, appStillExists: false)
        #expect(next == UninstallFlow.AfterRun(stage: .finishedWithProblems, refresh: true, reloadPlan: false))
    }

    @Test func onlyThePlanStageCanMoveThings() {
        #expect(UninstallStage.plan.canMove)
        #expect(!UninstallStage.moved.canMove)
        #expect(!UninstallStage.finishedWithProblems.canMove)
    }
}
