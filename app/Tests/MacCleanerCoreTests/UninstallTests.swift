import Testing
@testable import MacCleanerCore

@Suite struct UninstallTests {
    // MARK: last opened

    @Test func lastOpenedFollowsTheScriptsLabels() {
        #expect(LastOpened(days: -1) == .never)
        #expect(LastOpened(days: -30) == .never)
        #expect(LastOpened(days: Int.min) == .never)
        #expect(LastOpened(days: 0) == .today)
        #expect(LastOpened(days: 1) == .daysAgo(1))
        #expect(LastOpened(days: 412) == .daysAgo(412))
    }

    // MARK: apps-scan input and summary

    @Test func scanDaysAcceptsOnlyUpToSixDigits() {
        #expect(ScanDays.parse("90") == 90)
        #expect(ScanDays.parse(" 90 ") == 90)
        #expect(ScanDays.parse("0") == 0)
        #expect(ScanDays.parse("007") == 7)
        #expect(ScanDays.parse("999999") == 999_999)
        for bad in ["", "  ", "abc", "-5", "9.5", "1e3", "1000000", "९०"] { #expect(ScanDays.parse(bad) == nil, "\(bad)") }
        #expect(ScanDays.defaultDays == 90)
    }

    @Test func appsSummaryReadsTheMeta() throws {
        let s = try #require(AppsSummary(meta: ["total": "31", "rare_n": "6", "rare_kb": "5242880"]))
        #expect(s.total == 31 && s.rareCount == 6 && s.rareKB == 5_242_880)
        #expect(AppsSummary(meta: ["total": "31", "rare_n": "6"]) == nil)
        #expect(AppsSummary(meta: ["total": "x", "rare_n": "6", "rare_kb": "1"]) == nil)
    }

    // MARK: search

    private func entries(_ names: [String]) -> [AppEntry] {
        names.compactMap { AppEntry(fields: [$0, "/Applications/\($0).app"]) }
    }

    @Test func searchMatchesPartOfTheNameIgnoringCase() {
        let all = entries(["Figma", "Visual Studio Code", "Slack", "Notion"])
        #expect(AppEntry.filter(all, query: "").count == 4)
        #expect(AppEntry.filter(all, query: "   ").count == 4)
        #expect(AppEntry.filter(all, query: "studio").map(\.name) == ["Visual Studio Code"])
        #expect(AppEntry.filter(all, query: " SLA ").map(\.name) == ["Slack"])
        #expect(AppEntry.filter(all, query: "zzz").isEmpty)
        // the query is matched against the name, not the path
        #expect(AppEntry.filter(all, query: "applications").isEmpty)
    }

    // MARK: uninstall plan

    private static let app = "/Applications/Figma.app"
    private static let home = "/Users/demo/Library"

    private func rows(_ items: [(String, [String])]) -> [EngineRow] {
        items.map { EngineRow(kind: $0.0, fields: $0.1) }
    }

    private func meta(dup: String = "", vendor: String = "0", bid: String = "com.figma.Desktop") -> [String: String] {
        ["name": "Figma", "bundle_id": bid, "app_kb": "880000", "dup": dup, "vendor_hint": vendor]
    }

    private func plan(dup: String = "", extra: [(String, [String])] = []) throws -> UninstallPlan {
        let r = rows([
            ("leftover", ["1000", "\(Self.home)/Preferences/com.figma.Desktop.plist"]),
            ("leftover", ["2000", "\(Self.home)/Application Support/Figma"]),
            ("leftover", ["300", "\(Self.home)/Caches/com.figma.Desktop"]),
            ("admin", ["/Library/LaunchDaemons/com.figma.helper.plist"]),
        ] + extra)
        return try #require(UninstallPlan(appPath: Self.app, meta: meta(dup: dup), rows: r))
    }

    @Test func planReadsMetaAndRows() throws {
        let p = try plan()
        #expect(p.name == "Figma")
        #expect(p.bundleID == "com.figma.Desktop")
        #expect(p.appKB == 880_000)
        #expect(p.dupPath == nil)
        #expect(!p.vendorHint)
        #expect(p.leftovers.map(\.kb) == [1000, 2000, 300])
        #expect(p.adminPaths == ["/Library/LaunchDaemons/com.figma.helper.plist"])
        #expect(p.appFolder == "/Applications")
    }

    @Test func emptyBundleIDAndVendorHint() throws {
        let p = try #require(UninstallPlan(appPath: "/Applications/Vendor/Tool.app",
                                           meta: meta(vendor: "1", bid: ""), rows: []))
        #expect(p.bundleID == nil)
        #expect(p.vendorHint)
        #expect(p.appFolder == "/Applications/Vendor")
        #expect(p.leftovers.isEmpty)
    }

    @Test func planNeedsItsMeta() {
        #expect(UninstallPlan(appPath: Self.app, meta: [:], rows: []) == nil)
        var m = meta(); m["app_kb"] = "big"
        #expect(UninstallPlan(appPath: Self.app, meta: m, rows: []) == nil)
        m = meta(); m["name"] = nil
        #expect(UninstallPlan(appPath: Self.app, meta: m, rows: []) == nil)
    }

    @Test func aDuplicateCopyOffersNoLeftovers() throws {
        let p = try plan(dup: "/Users/demo/Applications/Figma.app")
        #expect(p.dupPath == "/Users/demo/Applications/Figma.app")
        #expect(p.leftovers.isEmpty)
        #expect(p.listLines(checked: ["\(Self.home)/Application Support/Figma"]).isEmpty)
        #expect(p.totalKB(checked: ["\(Self.home)/Application Support/Figma"]) == 880_000)
    }

    @Test func totalIsTheAppPlusTheCheckedLeftovers() throws {
        let p = try plan()
        let all = Set(p.leftovers.map(\.path))
        #expect(p.totalKB(checked: all) == 880_000 + 3300)
        #expect(p.totalKB(checked: []) == 880_000)
        #expect(p.totalKB(checked: [p.leftovers[1].path]) == 882_000)
        #expect(p.totalKB(checked: ["/not/in/the/plan"]) == 880_000)
    }

    @Test func listLinesAreOnlyCheckedLeftoversFromThePlan() throws {
        let p = try plan()
        let pref = p.leftovers[0].path, support = p.leftovers[1].path
        #expect(p.listLines(checked: [pref, support]) == [pref, support])  // plan order
        #expect(p.listLines(checked: []).isEmpty)  // an empty list means "app only"
        // a path the plan never offered cannot get into the list
        #expect(p.listLines(checked: [pref, "/etc/passwd", Self.app, "/Users/demo"]) == [pref])
        #expect(p.checkedLeftovers([support]).map(\.kb) == [2000])
    }

    @Test func theAppPathAndRepeatsNeverBecomeLeftovers() throws {
        let p = try plan(extra: [
            ("leftover", ["9", Self.app]),                                          // the app itself
            ("leftover", ["1000", "\(Self.home)/Preferences/com.figma.Desktop.plist"]),  // repeated
            ("leftover", ["x", "\(Self.home)/Caches/bad"]),                         // not a number
            ("admin", []),                                                          // malformed
        ])
        #expect(p.leftovers.count == 3)
        #expect(!p.leftovers.contains { $0.path == Self.app })
        #expect(p.listLines(checked: Set([Self.app] + p.leftovers.map(\.path))).count == 3)
        #expect(p.adminPaths.count == 1)
    }

    @Test func pathsThatCouldBreakTheListFileAreNotOffered() throws {
        let p = try plan(extra: [
            ("leftover", ["5", "\(Self.home)/Caches/a\nb"]),
            ("leftover", ["5", ""]),
        ])
        #expect(p.leftovers.count == 3)
    }

    // MARK: the days of the scan on screen

    @Test func scanDaysComeFromTheLastScanCommand() {
        #expect(ScanDays.days(inScan: ["apps-scan", "30"]) == 30)
        #expect(ScanDays.days(inScan: ["apps-scan", "007"]) == 7)
        #expect(ScanDays.days(inScan: nil) == nil)
        #expect(ScanDays.days(inScan: ["apps-scan"]) == nil)
        #expect(ScanDays.days(inScan: ["apps-list", "30"]) == nil)
        #expect(ScanDays.days(inScan: ["apps-scan", "x"]) == nil)
    }
}
