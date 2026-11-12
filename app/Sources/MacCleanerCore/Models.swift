import Foundation

// Typed views of the engine's `@@row` records. Every `init?(fields:)` takes the fields after the
// row kind and returns nil on the wrong field count, a size that isn't plain digits (see `parseCount`)
// or an unknown enum value.

public enum CacheKind: String, Sendable { case safe, heavy, permanent }
public enum CachePreset: Sendable { case safe, safeAndHeavy }

public struct CacheItem: Sendable, Equatable, Identifiable {
    public let id: String
    /// -1 means the size is unknown (the Trash); the UI shows "?".
    public let kb: Int
    public let kind: CacheKind
    public let label: String

    public init?(fields: [String]) {
        guard fields.count == 4, let kb = parseCount(fields[1], unknown: true), let kind = CacheKind(rawValue: fields[2]) else { return nil }
        self.id = fields[0]; self.kb = kb; self.kind = kind; self.label = fields[3]
    }

    public static func select(_ items: [CacheItem], preset: CachePreset) -> Set<String> {
        Set(items.filter { preset == .safe ? $0.kind == .safe : $0.kind != .permanent }.map(\.id))
    }

    public static func totalKB(_ items: [CacheItem], selected: Set<String>) -> Int {
        items.filter { selected.contains($0.id) && $0.kb >= 0 }.reduce(0) { $0 + $1.kb }
    }
}

public struct DirUsage: Sendable, Equatable, Identifiable {
    public let kb: Int
    public let path: String
    public var id: String { path }

    public init?(fields: [String]) {
        guard fields.count == 2, let kb = parseCount(fields[0]) else { return nil }
        self.kb = kb; self.path = fields[1]
    }
}

public struct MemApp: Sendable, Equatable, Identifiable {
    public let kb: Int
    public let path: String
    public let name: String
    public let note: String
    public let isHost: Bool
    public var id: String { path }

    public init?(fields: [String]) {
        guard fields.count == 5, let kb = parseCount(fields[0]), let host = parseFlag(fields[4]) else { return nil }
        self.kb = kb; self.path = fields[1]; self.name = fields[2]; self.note = fields[3]; self.isHost = host
    }
}

public struct MemProc: Sendable, Equatable, Identifiable {
    public let kb: Int
    public let path: String
    public let note: String
    public var id: String { path }

    public init?(fields: [String]) {
        guard fields.count == 3, let kb = parseCount(fields[0]) else { return nil }
        self.kb = kb; self.path = fields[1]; self.note = fields[2]
    }
}

/// The `ram-scan` meta values, all integers.
public struct MemSummary: Sendable, Equatable {
    public let total, app, wired, comp, cached, used, swap, level: Int

    public init?(meta: [String: String]) {
        func int(_ key: String) -> Int? { meta[key].flatMap { Int($0) } }
        guard let total = int("total"), let app = int("app"), let wired = int("wired"), let comp = int("comp"),
              let cached = int("cached"), let used = int("used"), let swap = int("swap"), let level = int("level")
        else { return nil }
        self.total = total; self.app = app; self.wired = wired; self.comp = comp
        self.cached = cached; self.used = used; self.swap = swap; self.level = level
    }
}

public struct AppUsage: Sendable, Equatable, Identifiable {
    public let kb: Int
    /// Days since last use; -1 means never recorded.
    public let days: Int
    public let isRare: Bool
    public let name: String
    public let path: String
    public var id: String { path }

    public init?(fields: [String]) {
        guard fields.count == 5, let kb = parseCount(fields[0]), let days = parseCount(fields[1], unknown: true), let rare = parseFlag(fields[2]) else { return nil }
        self.kb = kb; self.days = days; self.isRare = rare; self.name = fields[3]; self.path = fields[4]
    }
}

public struct AppEntry: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public var id: String { path }

    public init?(fields: [String]) {
        guard fields.count == 2 else { return nil }
        self.name = fields[0]; self.path = fields[1]
    }
}

public struct Leftover: Sendable, Equatable, Identifiable {
    public let kb: Int
    public let path: String
    public var id: String { path }

    public init?(fields: [String]) {
        guard fields.count == 2, let kb = parseCount(fields[0]) else { return nil }
        self.kb = kb; self.path = fields[1]
    }
}

/// One `docker system df` line. All values are display strings.
public struct DockerDF: Sendable, Equatable, Identifiable {
    public let type, total, active, size, reclaimable: String
    public var id: String { type }

    public init?(fields: [String]) {
        guard fields.count == 5 else { return nil }
        self.type = fields[0]; self.total = fields[1]; self.active = fields[2]
        self.size = fields[3]; self.reclaimable = fields[4]
    }
}

public struct DockerContainer: Sendable, Equatable, Identifiable {
    public let id: String
    public let state: String
    public let size: String
    public let name: String
    public let image: String
    public var isRunning: Bool { state == "running" }
    /// Stopped as the CLI's quick clean and `docker container prune` mean it: exited, created or dead. Paused and
    /// restarting containers still run.
    public var isStopped: Bool { ["exited", "created", "dead"].contains(state) }
    /// Removing it (`docker rm -f`) stops it first: anything not stopped, e.g. running, paused or restarting.
    public var stopsFirst: Bool { !isStopped }

    public init?(fields: [String]) {
        guard fields.count == 5 else { return nil }
        self.id = fields[0]; self.state = fields[1]; self.size = fields[2]; self.name = fields[3]; self.image = fields[4]
    }

    public static func stoppedIDs(_ items: [DockerContainer]) -> [String] {
        items.filter(\.isStopped).map(\.id)
    }
}

public enum ImageStatus: String, Sendable {
    case inUse = "in_use", unused, dangling
}

public struct DockerImage: Sendable, Equatable, Identifiable {
    public let ref: String
    public let size: String
    public let created: String
    public let status: ImageStatus
    public var id: String { ref }

    public init?(fields: [String]) {
        guard fields.count == 4, let status = ImageStatus(rawValue: fields[3]) else { return nil }
        self.ref = fields[0]; self.size = fields[1]; self.created = fields[2]; self.status = status
    }
}

public struct DockerVolume: Sendable, Equatable, Identifiable {
    public let name: String
    public let links: Int
    public let size: String
    /// Empty when no container uses the volume.
    public let usedBy: String
    public var id: String { name }
    public var inUse: Bool { links > 0 }

    public init?(fields: [String]) {
        guard fields.count == 4, let links = Int(fields[1]) else { return nil }
        self.name = fields[0]; self.links = links; self.size = fields[2]; self.usedBy = fields[3]
    }

    public static func unusedNames(_ items: [DockerVolume]) -> [String] {
        items.filter { !$0.inUse }.map(\.name)
    }
}

/// One entry of the current builder's cache (`docker buildx du`). Size and time are display strings.
public struct DockerBuildCache: Sendable, Equatable, Identifiable {
    public let id: String
    public let size: String
    public let lastUsed: String
    /// BuildKit's record type: regular, exec.cachemount, source.local, frontend, internal…
    public let type: String
    /// Its data is also part of an image, so removing it may free little space.
    public let shared: Bool
    /// Not in use, so prune can remove it.
    public let reclaimable: Bool
    /// The build step that made it (often a Dockerfile line); may be empty.
    public let step: String
    /// What the list shows: the step, or else the record type when it says more than "regular"; empty when neither does.
    public var title: String { step.isEmpty && type != "regular" ? type : step }

    public init?(fields: [String]) {
        guard fields.count == 7, !fields[0].isEmpty,
              let shared = Bool(fields[4]), let reclaimable = Bool(fields[5]) else { return nil }
        self.id = fields[0]; self.size = fields[1]; self.lastUsed = fields[2]; self.type = fields[3]
        self.shared = shared; self.reclaimable = reclaimable; self.step = fields[6]
    }
}

public enum UpdateKind: String, Sendable { case formula, cask, dmg, sparkle, mas }

public struct UpdateItem: Sendable, Equatable, Identifiable {
    public let kind: UpdateKind
    public let name, from, to, via, ref, app, homepage: String
    public var id: String { "\(kind.rawValue):\(ref.isEmpty ? app : ref)" }

    /// The `updates-apply --list` line: TAB-joined `kind, name, from, to, ref, app, homepage` (no `via`).
    public var listLine: String { [kind.rawValue, name, from, to, ref, app, homepage].joined(separator: "\t") }

    public init?(fields: [String]) {
        guard fields.count == 8, let kind = UpdateKind(rawValue: fields[0]) else { return nil }
        self.kind = kind; self.name = fields[1]; self.from = fields[2]; self.to = fields[3]
        self.via = fields[4]; self.ref = fields[5]; self.app = fields[6]; self.homepage = fields[7]
    }

    /// The `auto_skip` meta value: cask names joined with ", ", possibly empty.
    public static func autoSkipNames(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public struct DiskInfo: Sendable, Equatable {
    public let totalKB: Int
    public let freeKB: Int

    public init(totalKB: Int, freeKB: Int) { self.totalKB = totalKB; self.freeKB = freeKB }

    public init?(fields: [String]) {
        guard fields.count == 2, let total = parseCount(fields[0]), let free = parseCount(fields[1]) else { return nil }
        self.init(totalKB: total, freeKB: free)
    }
}

public enum ListFile {
    /// Writes one item per line (UTF-8, trailing newline) to a new unique file in the temporary directory.
    public static func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mac-cleaner-list-\(UUID().uuidString).txt")
        let text = lines.map { $0 + "\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// A size or a count from the engine: ASCII digits only, so a sign, a space or an overflow makes it no number.
/// `unknown` also accepts the engine's "-1" (unknown), which only the Trash size and the days since last use use.
func parseCount(_ s: String, unknown: Bool = false) -> Int? {
    if unknown, s == "-1" { return -1 }
    guard !s.isEmpty, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
    return Int(s)
}

private func parseFlag(_ s: String) -> Bool? {
    switch s {
    case "0": return false
    case "1": return true
    default: return nil
    }
}
