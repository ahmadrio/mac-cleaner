import Foundation

/// The kernel's memory pressure (`kern.memorystatus_vm_pressure_level`), as `ram-scan` reports it in `level`.
public enum MemPressure: Equatable, Sendable {
    case normal, warning, critical, unknown

    /// 1 = normal, 2 = warning, 4 = critical; anything else (the engine sends 0 when the level is unavailable) is unknown.
    public init(level: String) {
        switch level {
        case "1": self = .normal
        case "2": self = .warning
        case "4": self = .critical
        default: self = .unknown
        }
    }
}

extension MemSummary {
    public var pressure: MemPressure { MemPressure(level: String(level)) }

    /// Used RAM as a whole percent of the total, like the script's `M_USED * 100 / M_TOTAL`. 0 when the total is unknown.
    public var usedPercent: Int { total > 0 ? used * 100 / total : 0 }

    /// Used RAM as a share of the total for a bar, kept within 0...1. 0 when the total is unknown.
    public var usedFraction: Double { total > 0 ? min(max(Double(used) / Double(total), 0), 1) : 0 }
}

extension MemApp {
    /// The host row (Mac Cleaner itself) is shown but never offered for quitting.
    public var isSelectable: Bool { !isHost }
}

/// A value before and after an action ("RAM used", "Cached files"), in kilobytes.
public struct BeforeAfter: Hashable, Sendable {
    public let before: Int
    public let after: Int

    public init(before: Int, after: Int) { self.before = before; self.after = after }

    /// From two integer meta values, e.g. `ram-purge`'s `cached_before` and `cached_after`; nil if either is missing or not a number.
    public init?(meta: [String: String], before: String, after: String) {
        guard let b = meta[before].flatMap({ Int($0) }), let a = meta[after].flatMap({ Int($0) }) else { return nil }
        self.init(before: b, after: a)
    }

    /// "12.4 GB → 9.0 GB"
    public var text: String { "\(ByteFormat.string(kb: before)) → \(ByteFormat.string(kb: after))" }
}

/// The RAM screen's banner after quitting apps or a purge; kept in `JobModel.outcome` so it outlives a switch of
/// screen or language. The view adds the label ("RAM used", "Cached files").
public enum RAMOutcome: Hashable, Sendable {
    case ramUsed(BeforeAfter)
    case cachedFiles(BeforeAfter)
}
