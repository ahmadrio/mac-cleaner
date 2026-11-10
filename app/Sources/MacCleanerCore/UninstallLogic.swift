import Foundation

/// When an app was last opened, from the `days` field of an `app` row (the script's t_never / t_today / t_ago).
public enum LastOpened: Equatable, Sendable {
    case never, today, daysAgo(Int)

    /// -1 (or any negative number) means macOS has no record; 0 is today.
    public init(days: Int) {
        self = days < 0 ? .never : days == 0 ? .today : .daysAgo(days)
    }
}

extension AppUsage {
    public var lastOpened: LastOpened { LastOpened(days: days) }
}

/// The "unused after N days" field of the Rarely used apps screen.
public enum ScanDays {
    public static let defaultDays = 90

    /// Digits only, at most 6 (what `apps-scan` accepts), around optional spaces; nil otherwise.
    public static func parse(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard (1...6).contains(t.count), t.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(t)
    }
}

/// The `apps-scan` meta behind the summary line: how many apps are rarely used and how much space they take.
public struct AppsSummary: Equatable, Sendable {
    public let total: Int
    public let rareCount: Int
    public let rareKB: Int

    public init?(meta: [String: String]) {
        guard let total = meta["total"].flatMap({ Int($0) }), let n = meta["rare_n"].flatMap({ Int($0) }),
              let kb = meta["rare_kb"].flatMap({ Int($0) }) else { return nil }
        self.total = total; self.rareCount = n; self.rareKB = kb
    }
}

extension AppEntry {
    /// The apps whose name contains `query`, ignoring case (like the CLI's search); everything for a blank query.
    public static func filter(_ entries: [AppEntry], query: String) -> [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// What `uninstall-plan` found for one app. It is the only source of what the uninstall sheet may move:
/// the list file is built from `listLines`, which can only return leftovers of this plan.
public struct UninstallPlan: Equatable, Sendable {
    public let appPath: String
    public let name: String
    /// nil when the app has none (the meta value is empty).
    public let bundleID: String?
    public let appKB: Int
    /// Another installed copy of the app; when set, the leftovers are kept, so none are offered.
    public let dupPath: String?
    /// The app lives in its own folder, so its vendor may ship an uninstaller.
    public let vendorHint: Bool
    /// Leftovers in ~/Library the user may tick (empty when `dupPath` is set).
    public let leftovers: [Leftover]
    /// Found outside the home folder: shown for information, never moved.
    public let adminPaths: [String]

    /// nil when a meta value is missing or `app_kb` is not a number. Rows that don't fit, repeats, the app
    /// itself and paths that could not be written as one line of the list file are dropped.
    public init?(appPath: String, meta: [String: String], rows: [EngineRow]) {
        guard let name = meta["name"], let kb = meta["app_kb"].flatMap({ Int($0) }) else { return nil }
        self.appPath = appPath
        self.name = name
        self.bundleID = (meta["bundle_id"] ?? "").isEmpty ? nil : meta["bundle_id"]
        self.appKB = kb
        self.dupPath = (meta["dup"] ?? "").isEmpty ? nil : meta["dup"]
        self.vendorHint = meta["vendor_hint"] == "1"
        var seen: Set<String> = []
        var found: [Leftover] = []
        for row in rows where row.kind == "leftover" {
            guard let item = Leftover(fields: row.fields), Self.isListable(item.path), item.path != appPath,
                  seen.insert(item.path).inserted else { continue }
            found.append(item)
        }
        self.leftovers = dupPath == nil ? found : []
        self.adminPaths = rows.filter { $0.kind == "admin" && $0.fields.count == 1 }.map { $0.fields[0] }
    }

    private static func isListable(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\n") && !path.contains("\r") && !path.contains("\t")
    }

    /// The folder that holds the app.
    public var appFolder: String { URL(fileURLWithPath: appPath).deletingLastPathComponent().path }

    /// The plan's leftovers whose path is in `checked`, in plan order.
    public func checkedLeftovers(_ checked: Set<String>) -> [Leftover] {
        leftovers.filter { checked.contains($0.path) }
    }

    /// The app plus the checked leftovers, in kilobytes.
    public func totalKB(checked: Set<String>) -> Int {
        appKB + checkedLeftovers(checked).reduce(0) { $0 + $1.kb }
    }

    /// The `uninstall --list` lines: the checked leftovers, nothing else. Never the app path.
    public func listLines(checked: Set<String>) -> [String] {
        checkedLeftovers(checked).map(\.path)
    }
}
