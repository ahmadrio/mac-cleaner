import Foundation

/// The decisions behind the Updates screen, kept out of the view so they can be tested.
public enum UpdateLogic {
    /// Casks and DMG apps replace apps in /Applications, which macOS may guard with App Management.
    public static func needsAppManagement(selected: [UpdateItem]) -> Bool {
        selected.contains { $0.kind == .cask || $0.kind == .dmg }
    }

    /// A DMG app is swapped for Homebrew's version (old app to the Trash, then `brew install --cask`) only when
    /// Homebrew is present; without it the row just opens the download page.
    public static func replacesDMG(selected: [UpdateItem], hasBrew: Bool) -> Bool {
        hasBrew && selected.contains { $0.kind == .dmg }
    }

    /// The app paths that must not be running when the update starts: the selected DMG apps that will be replaced.
    /// The engine refuses a running one (`running`), so the app asks to quit them first. In order, no repeats.
    public static func dmgAppsToCheck(selected: [UpdateItem], hasBrew: Bool) -> [String] {
        guard hasBrew else { return [] }
        var seen: Set<String> = []
        return selected.filter { $0.kind == .dmg && !$0.app.isEmpty }.map(\.app).filter { seen.insert($0).inserted }
    }

    /// The rows left after dropping the DMG apps that are still running, and the names of those dropped.
    public struct Split: Equatable, Sendable {
        public let remaining: [UpdateItem]
        public let deselectedNames: [String]
    }

    /// `stillRunning` holds app paths; they are compared normalised (`//`, `.`), like the running check does.
    public static func deselectRunning(selected: [UpdateItem], stillRunning: Set<String>) -> Split {
        let running = Set(stillRunning.map(normalised))
        var remaining: [UpdateItem] = []
        var names: [String] = []
        for item in selected {
            if item.kind == .dmg, running.contains(normalised(item.app)) { names.append(item.name) } else { remaining.append(item) }
        }
        return Split(remaining: remaining, deselectedNames: names)
    }

    /// The `updates-apply --list` lines for these rows, exactly `UpdateItem.listLine`.
    public static func listLines(selected: [UpdateItem]) -> [String] { selected.map(\.listLine) }

    /// How an apply ended. `notRun` means the engine was never reached (every row skipped, or the list file failed).
    public enum ApplyEnd: Equatable, Sendable { case succeeded, failed, cancelled, notRun }

    /// Whether the list must be re-read after an apply. Any real run that reached the engine may have changed apps,
    /// even a failed one (the engine goes on after a failed step) or one whose password dialog was dismissed, so the
    /// old rows are stale: re-running one (e.g. a DMG row already replaced) would trash the app Homebrew just installed.
    public static func shouldRescan(after end: ApplyEnd, dryRun: Bool) -> Bool {
        end != .notRun && !dryRun
    }

    private static func normalised(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
}

extension UpdateItem {
    /// "name  from → to · via" as the confirmation lists it; an unknown installed version shows as "?".
    public var summaryLine: String { "\(name)  \(from.isEmpty ? "?" : from) → \(to) · \(via)" }
}

/// The notes under the update list, from the `updates-scan` meta. Broken or missing values count as "nothing to say".
public struct UpdateNotes: Equatable, Sendable {
    /// Homebrew is missing: DMG apps are checked but updated through their download page.
    public let noBrew: Bool
    /// Pinned formulae that were skipped.
    public let pinned: Int
    /// Self-updating casks that were not checked.
    public let autoSkip: [String]
    /// App Store apps `mas` didn't check (the engine reports 0 once `mas` has listed them).
    public let masCount: Int
    public let hasMas: Bool
    /// Homebrew's catalog couldn't be read, so only Sparkle apps were checked.
    public let offline: Bool

    public init(meta: [String: String]) {
        noBrew = meta["has_brew"] == "0"
        pinned = max(0, meta["pinned"].flatMap { Int($0) } ?? 0)
        autoSkip = UpdateItem.autoSkipNames(meta["auto_skip"] ?? "")
        masCount = max(0, meta["mas_n"].flatMap { Int($0) } ?? 0)
        hasMas = meta["has_mas"] == "1"
        offline = meta["offline"] == "1"
    }

    /// App Store apps that need the App Store because `mas` isn't installed.
    public var showsAppStoreButton: Bool { masCount > 0 && !hasMas }

    public var isEmpty: Bool { !noBrew && pinned == 0 && autoSkip.isEmpty && masCount == 0 && !offline }
}

/// The last `limit` lines of a log, for a panel that must stay responsive when a tool prints thousands (`brew upgrade`).
/// `hidden` is how many earlier lines are left out.
public struct LogTail: Equatable, Sendable {
    public let lines: [LogLine]
    public let hidden: Int

    public init(_ log: [LogLine], limit: Int) {
        let keep = max(0, limit)
        lines = Array(log.suffix(keep))
        hidden = log.count - lines.count
    }
}
