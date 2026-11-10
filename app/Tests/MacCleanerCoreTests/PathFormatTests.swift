import Testing
@testable import MacCleanerCore

@Suite struct PathFormatTests {
    @Test func replacesTheHomePrefix() {
        #expect(PathFormat.tilde("/Users/ana/Library/Caches", home: "/Users/ana") == "~/Library/Caches")
        #expect(PathFormat.tilde("/Users/ana/x", home: "/Users/ana") == "~/x")
    }

    @Test func homeItselfIsTilde() {
        #expect(PathFormat.tilde("/Users/ana", home: "/Users/ana") == "~")
    }

    @Test func onlyAWholeFolderNameMatches() {
        #expect(PathFormat.tilde("/Users/anabel/Library", home: "/Users/ana") == "/Users/anabel/Library")
        #expect(PathFormat.tilde("/Volumes/Users/ana/x", home: "/Users/ana") == "/Volumes/Users/ana/x")
    }

    @Test func otherPathsAndAnEmptyHomeStayAsTheyAre() {
        #expect(PathFormat.tilde("/opt/homebrew", home: "/Users/ana") == "/opt/homebrew")
        #expect(PathFormat.tilde("/opt/homebrew", home: "") == "/opt/homebrew")
        #expect(PathFormat.tilde("/Users/ana/x", home: "") == "/Users/ana/x")
    }

    @Test func aHomeWithATrailingSlashStillMatches() {
        #expect(PathFormat.tilde("/Users/ana/x", home: "/Users/ana/") == "~/x")
    }
}
