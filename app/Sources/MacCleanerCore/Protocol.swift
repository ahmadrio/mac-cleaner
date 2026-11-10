import Foundation

public enum LogLevel: String, Sendable { case info, ok, warn, err, say }

public enum EngineEvent: Equatable, Sendable {
    case progress(String, step: Int?, total: Int?)
    case log(LogLevel, String)
    case meta(String, String)
    case row(String, [String])
    case freed(Int)
    case disk(total: Int, free: Int)
    case error(String, String)
    case plain(String)
    case stderr(String)
    case exited(Int32)
}

/// Parses one stdout line of `mac-cleaner.command --engine`: `@@record<TAB>field<TAB>…`.
/// Anything that is not a well-formed record becomes `.plain`.
public enum ProtocolParser {
    public static func parse(_ line: String) -> EngineEvent {
        guard line.hasPrefix("@@") else { return .plain(line) }
        // Empty fields are significant (e.g. a memapp note), so never drop empty subsequences.
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let args = Array(parts.dropFirst())
        switch parts[0] {
        case "@@progress":
            if args.count == 1 { return .progress(args[0], step: nil, total: nil) }
            if args.count == 3, let step = parseCount(args[1]), let total = parseCount(args[2]) {
                return .progress(args[0], step: step, total: total)
            }
        case "@@log":
            if args.count == 2, let level = LogLevel(rawValue: args[0]) { return .log(level, args[1]) }
        case "@@meta":
            if args.count == 2 { return .meta(args[0], args[1]) }
        case "@@row":
            if let kind = args.first { return .row(kind, Array(args.dropFirst())) }
        case "@@freed":
            if args.count == 1, let kb = parseCount(args[0]) { return .freed(kb) }
        case "@@disk":
            if args.count == 2, let total = parseCount(args[0]), let free = parseCount(args[1]) {
                return .disk(total: total, free: free)
            }
        case "@@error":
            if args.count == 2 { return .error(args[0], args[1]) }
        default:
            break
        }
        return .plain(line)
    }
}
