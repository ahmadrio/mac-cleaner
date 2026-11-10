import Testing
@testable import MacCleanerCore

@Suite struct UpdateTests {
    private func item(_ kind: String, _ name: String, from: String = "1.0", to: String = "2.0", via: String = "Homebrew",
                      ref: String = "", app: String = "", homepage: String = "") -> UpdateItem {
        UpdateItem(fields: [kind, name, from, to, via, ref, app, homepage])!
    }

    private var formula: UpdateItem { item("formula", "wget", ref: "wget") }
    private var tapped: UpdateItem { item("formula", "terraform", ref: "hashicorp/tap/terraform") }
    private var cask: UpdateItem { item("cask", "iterm2", via: "Homebrew cask", ref: "iterm2") }
    private var dmg: UpdateItem { item("dmg", "Notion", ref: "notion", app: "/Applications/Notion.app", homepage: "https://www.notion.so") }
    private var sparkle: UpdateItem { item("sparkle", "Rectangle", via: "app's own updater", app: "/Applications/Rectangle.app") }
    private var mas: UpdateItem { item("mas", "Keynote", via: "App Store", ref: "409183694") }

    // MARK: App Management

    @Test func appManagementIsNeededForCasksAndDMGsOnly() {
        #expect(!UpdateLogic.needsAppManagement(selected: []))
        #expect(!UpdateLogic.needsAppManagement(selected: [formula, tapped, sparkle, mas]))
        #expect(UpdateLogic.needsAppManagement(selected: [formula, cask]))
        #expect(UpdateLogic.needsAppManagement(selected: [dmg]))
    }

    // MARK: running check

    @Test func dmgAppsToCheckAreTheSelectedDMGPathsWhenHomebrewReplacesThem() {
        #expect(UpdateLogic.dmgAppsToCheck(selected: [formula, cask, dmg, sparkle], hasBrew: true) == ["/Applications/Notion.app"])
        #expect(UpdateLogic.dmgAppsToCheck(selected: [formula, cask, sparkle, mas], hasBrew: true).isEmpty)
        // Without Homebrew a DMG row only opens its download page: no app is replaced, so none is checked.
        #expect(UpdateLogic.dmgAppsToCheck(selected: [dmg], hasBrew: false).isEmpty)
    }

    @Test func dmgAppsToCheckHasNoDuplicatesAndNoBlankPaths() {
        let again = item("dmg", "Notion (2)", ref: "notion", app: "/Applications/Notion.app")
        let blank = item("dmg", "Ghost", ref: "ghost", app: "")
        #expect(UpdateLogic.dmgAppsToCheck(selected: [dmg, again, blank], hasBrew: true) == ["/Applications/Notion.app"])
    }

    @Test func stillRunningDMGAppsAreDeselectedWithTheirNames() {
        let other = item("dmg", "Obsidian", ref: "obsidian", app: "/Applications/Obsidian.app")
        let split = UpdateLogic.deselectRunning(selected: [formula, dmg, other, cask],
                                                stillRunning: ["/Applications/Notion.app"])
        #expect(split.remaining == [formula, other, cask])
        #expect(split.deselectedNames == ["Notion"])
    }

    @Test func nothingRunningKeepsEverything() {
        let all = [formula, dmg, sparkle, mas]
        let split = UpdateLogic.deselectRunning(selected: all, stillRunning: [])
        #expect(split.remaining == all)
        #expect(split.deselectedNames.isEmpty)
    }

    @Test func onlyDMGRowsAreDeselectedEvenIfTheirAppIsRunning() {
        // A sparkle row opens the app on purpose, so a running app is no reason to drop it.
        let split = UpdateLogic.deselectRunning(selected: [sparkle], stillRunning: ["/Applications/Rectangle.app"])
        #expect(split.remaining == [sparkle])
        #expect(split.deselectedNames.isEmpty)
    }

    @Test func runningPathsMatchEvenWithDotsOrDoubleSlashes() {
        let split = UpdateLogic.deselectRunning(selected: [dmg], stillRunning: ["/Applications//./Notion.app"])
        #expect(split.remaining.isEmpty)
        #expect(split.deselectedNames == ["Notion"])
    }

    // MARK: list file

    @Test func listLinesAreTheSelectedRowsListLines() {
        let lines = UpdateLogic.listLines(selected: [formula, dmg])
        #expect(lines == [formula.listLine, dmg.listLine])
        #expect(lines[1] == "dmg\tNotion\t1.0\t2.0\tnotion\t/Applications/Notion.app\thttps://www.notion.so")
        #expect(UpdateLogic.listLines(selected: []).isEmpty)
    }

    @Test func listSentIsTheConfirmedRowsMinusTheDeselectedRunningApps() {
        let confirmed = [formula, dmg, cask]
        let split = UpdateLogic.deselectRunning(selected: confirmed, stillRunning: ["/Applications/Notion.app"])
        #expect(UpdateLogic.listLines(selected: split.remaining) == [formula.listLine, cask.listLine])
    }

    // MARK: confirm text

    @Test func summaryLineIsNameFromToVia() {
        #expect(cask.summaryLine == "iterm2  1.0 → 2.0 · Homebrew cask")
        let unknown = item("mas", "Keynote", from: "", to: "14.1", via: "App Store", ref: "409183694")
        #expect(unknown.summaryLine == "Keynote  ? → 14.1 · App Store")
    }

    @Test func dmgReplacementWarningNeedsADMGRowAndHomebrew() {
        #expect(UpdateLogic.replacesDMG(selected: [formula, dmg], hasBrew: true))
        #expect(!UpdateLogic.replacesDMG(selected: [formula, dmg], hasBrew: false))
        #expect(!UpdateLogic.replacesDMG(selected: [formula, cask, sparkle], hasBrew: true))
    }

    // MARK: notes

    @Test func notesReadTheScanMeta() {
        let notes = UpdateNotes(meta: ["has_brew": "1", "pinned": "2", "auto_skip": "Zoom, Firefox",
                                       "mas_n": "3", "has_mas": "0", "offline": "0"])
        #expect(notes.noBrew == false)
        #expect(notes.pinned == 2)
        #expect(notes.autoSkip == ["Zoom", "Firefox"])
        #expect(notes.masCount == 3)
        #expect(notes.hasMas == false)
        #expect(notes.offline == false)
        #expect(notes.showsAppStoreButton)
        #expect(!notes.isEmpty)
    }

    @Test func masAppsWithMasInstalledNeedNoAppStoreButton() {
        let notes = UpdateNotes(meta: ["has_brew": "1", "mas_n": "3", "has_mas": "1"])
        #expect(notes.masCount == 3 && notes.hasMas)
        #expect(!notes.showsAppStoreButton)
        #expect(!UpdateNotes(meta: ["has_brew": "1", "mas_n": "0", "has_mas": "0"]).showsAppStoreButton)
    }

    @Test func noHomebrewAndOfflineAreNotes() {
        #expect(UpdateNotes(meta: ["has_brew": "0"]).noBrew)
        #expect(UpdateNotes(meta: ["has_brew": "1", "offline": "1"]).offline)
        #expect(!UpdateNotes(meta: ["has_brew": "1"]).noBrew)
    }

    @Test func emptyOrBrokenMetaGivesNoNotes() {
        #expect(UpdateNotes(meta: [:]).isEmpty)
        #expect(UpdateNotes(meta: ["pinned": "x", "mas_n": "-4", "auto_skip": " , "]).isEmpty)
        #expect(UpdateNotes(meta: ["has_brew": "1", "pinned": "0", "auto_skip": "", "mas_n": "0", "has_mas": "1", "offline": "0"]).isEmpty)
    }

    // MARK: log window

    private func lines(_ n: Int) -> [LogLine] {
        (0..<n).map { LogLine(id: $0, level: nil, text: "line \($0)") }
    }

    @Test func logTailKeepsTheLastLinesAndCountsTheHiddenOnes() {
        let tail = LogTail(lines(1200), limit: 500)
        #expect(tail.lines.count == 500)
        #expect(tail.lines.first?.id == 700 && tail.lines.last?.id == 1199)
        #expect(tail.hidden == 700)
    }

    @Test func logTailShowsAShortLogWhole() {
        let tail = LogTail(lines(3), limit: 500)
        #expect(tail.lines.map(\.id) == [0, 1, 2])
        #expect(tail.hidden == 0)
        #expect(LogTail(lines(500), limit: 500).hidden == 0)
        #expect(LogTail(lines(501), limit: 500).hidden == 1)
        #expect(LogTail([], limit: 500).lines.isEmpty)
    }
}
