import Foundation
import Testing
@testable import MacCleanerCore

private func cache(_ id: String, _ kb: Int, _ kind: CacheKind) -> CacheItem {
    CacheItem(fields: [id, String(kb), kind.rawValue, id])!
}

@Test func cacheItemFromFields() {
    #expect(CacheItem(fields: ["npm", "2048", "safe", "npm / npx cache"])?.kind == .safe)
    #expect(CacheItem(fields: ["npm", "x", "safe", "l"]) == nil)
    #expect(CacheItem(fields: ["npm", "1", "bogus", "l"]) == nil)
    #expect(CacheItem(fields: ["npm", "1", "safe"]) == nil)
    #expect(CacheItem(fields: ["npm", "1", "safe", "l", "extra"]) == nil)
}

@Test func cacheItemAcceptsUnknownSize() {
    let trash = CacheItem(fields: ["trash", "-1", "permanent", "Trash"])
    #expect(trash?.kb == -1)
    #expect(trash?.id == "trash")
}

@Test func cachePresets() {
    let items = [cache("a", 100, .safe), cache("b", 200, .heavy), cache("c", 300, .permanent), cache("t", -1, .permanent)]
    #expect(CacheItem.select(items, preset: .safe) == ["a"])
    #expect(CacheItem.select(items, preset: .safeAndHeavy) == ["a", "b"])
    #expect(CacheItem.totalKB(items, selected: ["a", "b", "c", "t"]) == 600)
    #expect(CacheItem.totalKB(items, selected: ["t"]) == 0)
    #expect(CacheItem.totalKB(items, selected: []) == 0)
}

@Test func dirUsageAndLeftover() {
    #expect(DirUsage(fields: ["10", "/Users/a/Library/x"])?.path == "/Users/a/Library/x")
    #expect(DirUsage(fields: ["x", "/p"]) == nil)
    #expect(Leftover(fields: ["5", "/p"])?.kb == 5)
    #expect(Leftover(fields: ["5"]) == nil)
}

@Test func memAppKeepsEmptyNote() {
    let app = MemApp(fields: ["2998960", "/Applications/Google Chrome.app", "Google Chrome", "", "0"])
    #expect(app?.note == "")
    #expect(app?.isHost == false)
    #expect(MemApp(fields: ["1", "/p", "n", "", "1"])?.isHost == true)
    #expect(MemApp(fields: ["1", "/p", "n", "", "2"]) == nil)
    #expect(MemApp(fields: ["1", "/p", "n", "0"]) == nil)
}

@Test func memProc() {
    #expect(MemProc(fields: ["12", "/usr/bin/x", "note"])?.note == "note")
    #expect(MemProc(fields: ["z", "/usr/bin/x", "note"]) == nil)
}

@Test func memSummaryFromMeta() {
    let meta = ["total": "100", "app": "1", "wired": "2", "comp": "3", "cached": "4", "used": "5", "swap": "6", "level": "1"]
    let s = MemSummary(meta: meta)
    #expect(s?.total == 100)
    #expect(s?.cached == 4)
    #expect(s?.swap == 6)
    #expect(s?.level == 1)
    var missing = meta
    missing["swap"] = nil
    #expect(MemSummary(meta: missing) == nil)
    var bad = meta
    bad["used"] = "x"
    #expect(MemSummary(meta: bad) == nil)
}

@Test func appUsage() {
    let a = AppUsage(fields: ["500", "-1", "1", "Foo", "/Applications/Foo.app"])
    #expect(a?.days == -1)
    #expect(a?.isRare == true)
    #expect(AppUsage(fields: ["500", "30", "0", "Foo", "/p"])?.isRare == false)
    #expect(AppUsage(fields: ["500", "30", "7", "Foo", "/p"]) == nil)
    #expect(AppEntry(fields: ["Foo", "/p"])?.name == "Foo")
    #expect(AppEntry(fields: ["Foo"]) == nil)
}

@Test func dockerDF() {
    let df = DockerDF(fields: ["Images", "5", "2", "1.2GB", "800MB (66%)"])
    #expect(df?.type == "Images")
    #expect(df?.reclaimable == "800MB (66%)")
    #expect(DockerDF(fields: ["Images", "5"]) == nil)
}

@Test func dockerContainersAndStoppedIDs() {
    let run = DockerContainer(fields: ["a1", "running", "5B", "web", "nginx"])!
    let stop = DockerContainer(fields: ["b2", "exited", "0B", "db", "pg"])!
    #expect(run.isRunning)
    #expect(!stop.isRunning)
    #expect(DockerContainer.stoppedIDs([run, stop]) == ["b2"])
    #expect(DockerContainer(fields: ["a1", "running", "5B", "web"]) == nil)
}

@Test func stoppedMeansExitedCreatedOrDeadLikeTheCLI() {
    // The CLI's quick clean (and `docker container prune`) take exited, created and dead. Paused and restarting
    // containers still run: `rm -f` stops them first, so "All stopped" must not pick them.
    func c(_ id: String, _ state: String) -> DockerContainer { DockerContainer(fields: [id, state, "0B", id, "img"])! }
    let all = [c("r", "running"), c("e", "exited"), c("c", "created"), c("d", "dead"), c("p", "paused"),
               c("rs", "restarting"), c("rm", "removing")]
    #expect(all.filter(\.isStopped).map(\.id) == ["e", "c", "d"])
    #expect(DockerContainer.stoppedIDs(all) == ["e", "c", "d"])
    #expect(all.filter(\.stopsFirst).map(\.id) == ["r", "p", "rs", "rm"])
}

@Test func dockerImage() {
    #expect(DockerImage(fields: ["nginx:latest", "187MB", "2 weeks ago", "in_use"])?.status == .inUse)
    #expect(DockerImage(fields: ["abc123", "1MB", "1 day ago", "dangling"])?.status == .dangling)
    #expect(DockerImage(fields: ["x:1", "1MB", "1 day ago", "unused"])?.status == .unused)
    #expect(DockerImage(fields: ["x:1", "1MB", "1 day ago", "weird"]) == nil)
}

@Test func dockerVolumesAndUnusedNames() {
    let used = DockerVolume(fields: ["pgdata", "2", "1GB", "db +1"])!
    let free = DockerVolume(fields: ["old", "0", "5MB", ""])!
    #expect(used.inUse)
    #expect(used.usedBy == "db +1")
    #expect(!free.inUse)
    #expect(free.usedBy == "")
    #expect(DockerVolume.unusedNames([used, free]) == ["old"])
    #expect(DockerVolume(fields: ["v", "x", "1MB", ""]) == nil)
}

@Test func updateListLine() {
    let row = ["dmg", "Foo", "1.0", "2.0", "Direct download", "foo", "/Apps/Foo.app", "https://foo.example"]
    let u = UpdateItem(fields: row)
    #expect(u?.kind == .dmg)
    #expect(u?.listLine == "dmg\tFoo\t1.0\t2.0\tfoo\t/Apps/Foo.app\thttps://foo.example")
    #expect(u?.id == "dmg:foo")
}

@Test func updateIdFallsBackToAppAndKeepsEmptyFields() {
    let u = UpdateItem(fields: ["sparkle", "Bar", "1", "2", "Sparkle", "", "/Apps/Bar.app", ""])
    #expect(u?.id == "sparkle:/Apps/Bar.app")
    #expect(u?.listLine == "sparkle\tBar\t1\t2\t\t/Apps/Bar.app\t")
    #expect(UpdateItem(fields: ["bogus", "Bar", "1", "2", "v", "", "", ""]) == nil)
    #expect(UpdateItem(fields: ["cask", "Bar", "1", "2", "v", "", ""]) == nil)
}

@Test func diskInfo() {
    #expect(DiskInfo(fields: ["500", "120"]) == DiskInfo(totalKB: 500, freeKB: 120))
    #expect(DiskInfo(fields: ["500"]) == nil)
    #expect(DiskInfo(fields: ["a", "1"]) == nil)
}

@Test func listFileRoundTrip() throws {
    let paths = ["/Users/a/Library/Application Support/Café Notes", "/Users/a/Library/Preferences/com.x.plist"]
    let url = try ListFile.write(paths)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try String(contentsOf: url, encoding: .utf8) == paths.joined(separator: "\n") + "\n")
    #expect(url.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL)
}

@Test func listFilesAreUnique() throws {
    let a = try ListFile.write(["x"])
    let b = try ListFile.write(["x"])
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    #expect(a != b)
}

@Test func emptyListFileIsEmpty() throws {
    let url = try ListFile.write([])
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try String(contentsOf: url, encoding: .utf8) == "")
}

@Test func autoSkipNames() {
    #expect(UpdateItem.autoSkipNames("") == [])
    #expect(UpdateItem.autoSkipNames("firefox, google-chrome") == ["firefox", "google-chrome"])
}
