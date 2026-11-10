import Foundation

// The Docker screen's decisions, kept out of the views: which rows can be ticked, which actions exist and what
// each one requires, and what the screen shows for the engine's state.

extension DockerImage {
    /// An image a container uses can't be removed (the engine skips it too), so the screen never offers it.
    public var isSelectable: Bool { status != .inUse }

    /// The refs to put in the `docker-rm images` list file: ticked rows that are selectable, in list order.
    public static func refsToRemove(_ items: [DockerImage], selected: Set<String>) -> [String] {
        items.filter { $0.isSelectable && selected.contains($0.id) }.map(\.ref)
    }
}

extension DockerVolume {
    /// A volume a container uses can't be removed (the engine skips it too), so the screen never offers it.
    public var isSelectable: Bool { !inUse }

    /// The names to put in the `docker-rm volumes` list file: ticked rows that are selectable, in list order.
    public static func namesToRemove(_ items: [DockerVolume], selected: Set<String>) -> [String] {
        items.filter { $0.isSelectable && selected.contains($0.id) }.map(\.name)
    }
}

extension DockerContainer {
    /// The ids to put in the `docker-rm containers` list file: ticked rows, in list order. A running container
    /// may be ticked too (`docker rm -f`); the screen warns about those.
    public static func idsToRemove(_ items: [DockerContainer], selected: Set<String>) -> [String] {
        items.filter { selected.contains($0.id) }.map(\.id)
    }
}

/// One `docker-prune` action; the raw value is the engine argument.
public enum DockerAction: String, CaseIterable, Identifiable, Sendable {
    case imagesUnused = "images-unused"
    case imagesDangling = "images-dangling"
    case buildAll = "build-all"
    case buildOld = "build-old"
    case networks
    case safe
    case allUnused = "all-unused"
    case wipe
    case orbReset = "orb-reset"

    public static let orbStack = "OrbStack"

    public var id: String { rawValue }

    /// The word to type before confirming: `HAPUS`/`DELETE` for what deletes volumes, `RESET` for the two resets.
    public func typedWord(lang: String) -> String? {
        switch self {
        case .allUnused: Self.volumesTypedWord(lang: lang)
        case .wipe, .orbReset: "RESET"
        default: nil
        }
    }

    /// The word for removing volumes (also what "remove everything unused" asks for).
    public static func volumesTypedWord(lang: String) -> String { lang == "id" ? "HAPUS" : "DELETE" }

    /// Everything is available except the OrbStack factory reset, which needs the `meta engine` to be OrbStack.
    public func isShown(engine: String?) -> Bool { self != .orbReset || engine == Self.orbStack }

    /// The buttons of the "All at once" section, in the order they are shown.
    public static func allAtOnce(engine: String?) -> [DockerAction] {
        [.buildAll, .buildOld, .networks, .safe, .allUnused, .wipe, .orbReset].filter { $0.isShown(engine: engine) }
    }

    /// Without OrbStack the section ends with the hint for shrinking Docker Desktop's disk instead of the reset.
    public static func showsDesktopShrinkHint(engine: String?) -> Bool { engine != orbStack }
}

/// What the Docker screen shows for the engine's answer.
public enum DockerMode: Equatable, Sendable {
    case missing, stoppedOrbStack, stoppedDesktop, notReady, running

    /// From `docker-status`'s `meta state`. Without a state, from the `docker_missing` / `docker_not_ready`
    /// error an action or list came back with (R15). nil when neither says anything.
    public init?(meta: [String: String], failureCodes: [String]) {
        switch meta["state"] {
        case "missing": self = .missing
        case "stopped_orb": self = .stoppedOrbStack
        case "stopped_desktop": self = .stoppedDesktop
        case "stopped_other": self = .notReady
        case "running": self = .running
        case .some: return nil
        case nil:
            if failureCodes.contains("docker_missing") { self = .missing }
            else if failureCodes.contains("docker_not_ready") { self = .notReady }
            else { return nil }
        }
    }
}

/// The counts of `docker-status`. The engine sends them (and the `df` rows) only while the daemon runs (R16).
public struct DockerCounts: Sendable, Equatable {
    public let containers, running, images, volumes: Int

    public init(containers: Int, running: Int, images: Int, volumes: Int) {
        self.containers = containers; self.running = running; self.images = images; self.volumes = volumes
    }

    public init?(meta: [String: String]) {
        func int(_ key: String) -> Int? { meta[key].flatMap { Int($0) } }
        guard let containers = int("containers"), let running = int("running"),
              let images = int("images"), let volumes = int("volumes") else { return nil }
        self.init(containers: containers, running: running, images: images, volumes: volumes)
    }
}
