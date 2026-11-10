import Testing
@testable import MacCleanerCore

@Suite struct DockerLogicTests {
    // MARK: selectable rows

    @Test func inUseImagesAndVolumesAreNeverSelectable() throws {
        func image(_ status: String) throws -> DockerImage { try #require(DockerImage(fields: ["x:1", "5MB", "1 week ago", status])) }
        #expect(try !image("in_use").isSelectable)
        #expect(try image("unused").isSelectable)
        #expect(try image("dangling").isSelectable)
        let used = try #require(DockerVolume(fields: ["pgdata", "1", "120MB", "db"]))
        let unused = try #require(DockerVolume(fields: ["cache", "0", "50MB", ""]))
        #expect(!used.isSelectable)
        #expect(unused.isSelectable)
    }

    @Test func removalListsOnlyTickedSelectableRows() throws {
        let images = try [["nginx:latest", "in_use"], ["old:1", "unused"], ["abc123def456", "dangling"]]
            .map { try #require(DockerImage(fields: [$0[0], "1MB", "now", $0[1]])) }
        // a stale tick on an in-use image never reaches the list file
        #expect(DockerImage.refsToRemove(images, selected: ["nginx:latest", "old:1", "gone:1"]) == ["old:1"])
        #expect(DockerImage.refsToRemove(images, selected: []) == [])
        let volumes = try [["pgdata", "1"], ["cache", "0"], ["tmp", "0"]]
            .map { try #require(DockerVolume(fields: [$0[0], $0[1], "1MB", $0[1] == "0" ? "" : "db"])) }
        #expect(DockerVolume.namesToRemove(volumes, selected: ["pgdata", "tmp"]) == ["tmp"])
        let containers = try [["a1", "running", "web"], ["b2", "exited", "db"]]
            .map { try #require(DockerContainer(fields: [$0[0], $0[1], "0B", $0[2], "img"])) }
        #expect(DockerContainer.idsToRemove(containers, selected: ["b2", "zz"]) == ["b2"])
        #expect(DockerContainer.idsToRemove(containers, selected: ["a1", "b2"]) == ["a1", "b2"])  // running ones too, with a warning
    }

    // MARK: actions

    @Test func engineArgumentsMatchTheEngineCommand() {
        let all = DockerAction.allCases.map(\.rawValue)
        #expect(all == ["images-unused", "images-dangling", "build-all", "build-old", "networks", "safe", "all-unused", "wipe", "orb-reset"])
    }

    @Test func typedWordsFollowTheSafetyRules() {
        for action in DockerAction.allCases {
            let expected: String?
            switch action {
            case .allUnused: expected = "HAPUS"
            case .wipe, .orbReset: expected = "RESET"
            default: expected = nil
            }
            #expect(action.typedWord(lang: "id") == expected, "\(action)")
        }
        #expect(DockerAction.allUnused.typedWord(lang: "en") == "DELETE")
        #expect(DockerAction.wipe.typedWord(lang: "en") == "RESET")
        #expect(DockerAction.orbReset.typedWord(lang: "id") == "RESET")
        #expect(DockerAction.volumesTypedWord(lang: "id") == "HAPUS")
        #expect(DockerAction.volumesTypedWord(lang: "en") == "DELETE")
    }

    @Test func orbResetIsShownOnlyForOrbStack() {
        for action in DockerAction.allCases where action != .orbReset {
            #expect(action.isShown(engine: "Docker") && action.isShown(engine: "OrbStack") && action.isShown(engine: nil))
        }
        #expect(DockerAction.orbReset.isShown(engine: "OrbStack"))
        #expect(!DockerAction.orbReset.isShown(engine: "Docker"))
        #expect(!DockerAction.orbReset.isShown(engine: nil))
    }

    @Test func allAtOnceSectionOrderAndEngine() {
        #expect(DockerAction.allAtOnce(engine: "OrbStack") == [.buildAll, .buildOld, .networks, .safe, .allUnused, .wipe, .orbReset])
        #expect(DockerAction.allAtOnce(engine: "Docker") == [.buildAll, .buildOld, .networks, .safe, .allUnused, .wipe])
        #expect(DockerAction.showsDesktopShrinkHint(engine: "Docker"))
        #expect(!DockerAction.showsDesktopShrinkHint(engine: "OrbStack"))
    }

    // MARK: state → UI mode

    @Test func stateMapsToMode() {
        func mode(_ state: String?, _ failures: [String] = []) -> DockerMode? {
            DockerMode(meta: state.map { ["state": $0] } ?? [:], failureCodes: failures)
        }
        #expect(mode("missing") == .missing)
        #expect(mode("stopped_orb") == .stoppedOrbStack)
        #expect(mode("stopped_desktop") == .stoppedDesktop)
        #expect(mode("stopped_other") == .notReady)
        #expect(mode("running") == .running)
        #expect(mode("bogus") == nil)
        #expect(mode(nil) == nil)
    }

    @Test func errorsMapToModeWhenThereIsNoState() {
        func mode(_ failures: [String]) -> DockerMode? { DockerMode(meta: [:], failureCodes: failures) }
        #expect(mode(["docker_missing"]) == .missing)       // R15: the docker (or orb) binary is absent
        #expect(mode(["docker_not_ready"]) == .notReady)    // R15: the daemon doesn't answer
        #expect(mode(["bad_args"]) == nil)
        // a known state wins over an error from an action that ran meanwhile
        #expect(DockerMode(meta: ["state": "running"], failureCodes: ["docker_not_ready"]) == .running)
    }

    @Test func countsExistOnlyWithAllFourValues() {  // R16
        let meta = ["containers": "3", "running": "1", "images": "4", "volumes": "2"]
        let counts = DockerCounts(meta: meta)
        #expect(counts == DockerCounts(containers: 3, running: 1, images: 4, volumes: 2))
        var partial = meta
        partial["volumes"] = nil
        #expect(DockerCounts(meta: partial) == nil)
        #expect(DockerCounts(meta: ["state": "stopped_orb"]) == nil)
        partial["volumes"] = "x"
        #expect(DockerCounts(meta: partial) == nil)
    }

    // MARK: quick clean confirmation

    @Test func quickCleanListsTheStoppedContainersTheProbeFound() {
        func c(_ id: String, _ state: String) -> DockerContainer { DockerContainer(fields: [id, state, "0B", id, "img"])! }
        let found = QuickCleanContainers(probeSucceeded: true, containers: [c("a", "running"), c("b", "exited"), c("p", "paused")])
        #expect(found == .listed([c("b", "exited")]))
        #expect(found.stopped.map(\.id) == ["b"])
        #expect(found.mentionsContainers)
    }

    @Test func quickCleanWithNoStoppedContainersNeedsNoContainerWarning() {
        let none = QuickCleanContainers(probeSucceeded: true, containers: [])
        #expect(none == .listed([]))
        #expect(!none.mentionsContainers)
    }

    @Test func aFailedProbeStillWarnsAboutStoppedContainers() {
        // `container prune` runs anyway, so the confirmation must not leave containers out.
        let unknown = QuickCleanContainers(probeSucceeded: false, containers: [])
        #expect(unknown == .unknown)
        #expect(unknown.stopped.isEmpty)
        #expect(unknown.mentionsContainers)
    }
}

@Test func dockerModeOffersActionsOnlyWhereThereAreSome() {
    #expect(DockerMode.running.offersActions)
    #expect(DockerMode.stoppedOrbStack.offersActions)
    #expect(DockerMode.stoppedDesktop.offersActions)
    #expect(!DockerMode.missing.offersActions)  // nothing to wait for: "another task is running" would only confuse
    #expect(!DockerMode.notReady.offersActions)
}
