import Testing
@testable import MacCleanerCore

@Suite struct RAMTests {
    @Test func pressureFollowsTheKernelLevels() {
        #expect(MemPressure(level: "1") == .normal)
        #expect(MemPressure(level: "2") == .warning)
        #expect(MemPressure(level: "4") == .critical)
        for other in ["0", "3", "5", "", "x", " 1", "1 "] { #expect(MemPressure(level: other) == .unknown, "level \(other)") }
    }

    @Test func summaryHasAPressure() {
        func pressure(_ level: Int) -> MemPressure? {
            MemSummary(meta: ["total": "1", "app": "1", "wired": "1", "comp": "1", "cached": "1", "used": "1", "swap": "0",
                              "level": String(level)])?.pressure
        }
        #expect(pressure(1) == .normal)
        #expect(pressure(2) == .warning)
        #expect(pressure(4) == .critical)
        #expect(pressure(0) == .unknown)  // the engine sends 0 when the kernel gives no level
    }

    @Test func theHostRowIsNeverSelectable() throws {
        let host = try #require(MemApp(fields: ["900000", "/Applications/Mac Cleaner.app", "Mac Cleaner", "", "1"]))
        let other = try #require(MemApp(fields: ["900000", "/Applications/Safari.app", "Safari", "", "0"]))
        #expect(!host.isSelectable)
        #expect(other.isSelectable)
    }

    private func summary(total: Int, used: Int) throws -> MemSummary {
        try #require(MemSummary(meta: ["total": String(total), "app": "0", "wired": "0", "comp": "0", "cached": "0",
                                       "used": String(used), "swap": "0", "level": "1"]))
    }

    @Test func usedPercentMatchesTheScript() throws {
        // The script: pct=$(( M_USED * 100 / M_TOTAL )), integer division.
        #expect(try summary(total: 16_777_216, used: 12_582_912).usedPercent == 75)
        #expect(try summary(total: 3, used: 1).usedPercent == 33)
        #expect(try summary(total: 100, used: 0).usedPercent == 0)
    }

    @Test func usedPercentSurvivesAZeroTotal() throws {
        let none = try summary(total: 0, used: 500)
        #expect(none.usedPercent == 0)
        #expect(none.usedFraction == 0)
    }

    @Test func usedFractionIsClampedForTheBar() throws {
        #expect(try summary(total: 200, used: 50).usedFraction == 0.25)
        #expect(try summary(total: 100, used: 150).usedFraction == 1)  // a bar can't be over full
        #expect(try summary(total: 100, used: -5).usedFraction == 0)
    }

    @Test func beforeAfterTextShowsBothSizes() {
        #expect(BeforeAfter(before: 13_000_000, after: 9_437_184).text == "12.4 GB → 9.0 GB")
        #expect(BeforeAfter(before: 2048, after: 512).text == "2 MB → 512 KB")
    }

    @Test func beforeAfterReadsTheMeta() {
        let meta = ["cached_before": "6291456", "cached_after": "1258291", "other": "1"]
        let pair = BeforeAfter(meta: meta, before: "cached_before", after: "cached_after")
        #expect(pair == BeforeAfter(before: 6_291_456, after: 1_258_291))
        #expect(BeforeAfter(meta: ["cached_before": "1"], before: "cached_before", after: "cached_after") == nil)
        #expect(BeforeAfter(meta: ["cached_before": "x", "cached_after": "1"], before: "cached_before", after: "cached_after") == nil)
    }
}
