import Testing
@testable import MacCleanerCore

@Test func parsesRow() {
    #expect(ProtocolParser.parse("@@row\tcache\tnpm\t2048\tsafe\tnpm / npx cache") == .row("cache", ["npm", "2048", "safe", "npm / npx cache"]))
}

@Test func parsesProgressSteps() {
    #expect(ProtocolParser.parse("@@progress\tFoo\t3\t10") == .progress("Foo", step: 3, total: 10))
}

@Test func parsesProgressText() {
    #expect(ProtocolParser.parse("@@progress\tMeasuring") == .progress("Measuring", step: nil, total: nil))
}

@Test func progressWithBadStepsIsPlain() {
    #expect(ProtocolParser.parse("@@progress\tFoo\tx\t10") == .plain("@@progress\tFoo\tx\t10"))
    #expect(ProtocolParser.parse("@@progress\tFoo\t3") == .plain("@@progress\tFoo\t3"))
}

@Test func emptyTrailingFieldsKept() {
    #expect(ProtocolParser.parse("@@row\tupdate\tformula\twget\t1\t2\tHomebrew\twget\t\t") == .row("update", ["formula", "wget", "1", "2", "Homebrew", "wget", "", ""]))
}

@Test func emptyMiddleFieldKept() {
    #expect(ProtocolParser.parse("@@row\tmemapp\t2998960\t/Applications/Google Chrome.app\tGoogle Chrome\t\t0")
        == .row("memapp", ["2998960", "/Applications/Google Chrome.app", "Google Chrome", "", "0"]))
}

@Test func plainAndUnknownAndMalformed() {
    #expect(ProtocolParser.parse("==> Upgrading wget") == .plain("==> Upgrading wget"))
    #expect(ProtocolParser.parse("@@bogus\tx") == .plain("@@bogus\tx"))
    #expect(ProtocolParser.parse("@@freed\tabc") == .plain("@@freed\tabc"))
    #expect(ProtocolParser.parse("") == .plain(""))
}

@Test func parsesDiskFreedErrorLog() {
    #expect(ProtocolParser.parse("@@disk\t500000000\t120000000") == .disk(total: 500_000_000, free: 120_000_000))
    #expect(ProtocolParser.parse("@@freed\t0") == .freed(0))
    #expect(ProtocolParser.parse("@@error\tfinder_denied\tNot authorized") == .error("finder_denied", "Not authorized"))
    #expect(ProtocolParser.parse("@@log\twarn\tQuit your IDE first") == .log(.warn, "Quit your IDE first"))
    #expect(ProtocolParser.parse("@@log\tloud\tx") == .plain("@@log\tloud\tx"))
}

@Test func parsesMeta() {
    #expect(ProtocolParser.parse("@@meta\ttotal_safe\t7254336") == .meta("total_safe", "7254336"))
    #expect(ProtocolParser.parse("@@meta\tauto_skip\t") == .meta("auto_skip", ""))
}

@Test func wrongFieldCountsArePlain() {
    #expect(ProtocolParser.parse("@@disk\t1") == .plain("@@disk\t1"))
    #expect(ProtocolParser.parse("@@disk\t1\tx") == .plain("@@disk\t1\tx"))
    #expect(ProtocolParser.parse("@@meta\tonly") == .plain("@@meta\tonly"))
    #expect(ProtocolParser.parse("@@error\tcode") == .plain("@@error\tcode"))
    #expect(ProtocolParser.parse("@@freed") == .plain("@@freed"))
    #expect(ProtocolParser.parse("@@row") == .plain("@@row"))
}
