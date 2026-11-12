import Foundation

// "Check for Updates…": what `self-update-check` found and where the update sheet stands, kept out of the view.

/// The latest release as `self-update-check` reports it: the running version, the latest one, whether that is newer,
/// the release page, the zip's size and the release notes (one `note` row per line).
public struct SelfUpdateRelease: Equatable, Sendable {
    public let current: String
    public let latest: String
    public let isNewer: Bool
    /// The release page (https only); nil when the engine gave none.
    public let page: URL?
    public let sizeBytes: Int
    public let notes: [String]

    /// nil unless the meta holds both versions and a clear `newer` (0 or 1).
    public init?(meta: [String: String], notes: [String]) {
        guard let current = meta["current"], !current.isEmpty, let latest = meta["latest"], !latest.isEmpty,
              let newer = meta["newer"], newer == "0" || newer == "1" else { return nil }
        self.current = current
        self.latest = latest
        isNewer = newer == "1"
        page = meta["page"].flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil }
        sizeBytes = max(0, meta["size"].flatMap { Int($0) } ?? 0)
        self.notes = notes
    }

    /// Where "Open the release page" goes when the engine gave no page (e.g. the check itself failed).
    public static let releasesPage = URL(string: "https://github.com/ahmadrio/mac-cleaner/releases/latest")!
}

/// Where the update sheet stands, from its job: the check is a scan, the update an action.
public enum SelfUpdateStage: Equatable, Sendable {
    case checking
    case checkFailed
    case upToDate(SelfUpdateRelease)
    case available(SelfUpdateRelease)
    case applying
    /// The app at `appPath` is the new version now: the app opens it again.
    case replaced(appPath: String)
    /// A dry run: the new version was downloaded and checked, nothing was replaced.
    case checkedOnly
    case applyFailed

    /// `hasActed` is the job's: true once the update ran (a plain scan, i.e. a new check, clears it).
    public init(phase: JobModel.Phase, hasActed: Bool, meta: [String: String], notes: [String]) {
        switch phase {
        case .idle, .scanning:
            self = .checking
        case .running:
            self = .applying
        case .done where hasActed:
            if meta["replaced"] == "1", let app = meta["app"], !app.isEmpty {
                self = .replaced(appPath: app)
            } else {
                self = .checkedOnly
            }
        case .failed where hasActed:
            self = .applyFailed
        case .failed:
            self = .checkFailed
        case .done:
            guard let release = SelfUpdateRelease(meta: meta, notes: notes) else { self = .checkFailed; return }
            self = release.isNewer ? .available(release) : .upToDate(release)
        }
    }
}

/// The release notes, as written for this repo's releases: English, a line `---`, then Indonesian (and possibly more
/// after another `---`, such as the zip's checksum).
public enum ReleaseNotes {
    /// The part in the UI language ("id" picks the second part), without blank lines at either end. Notes without
    /// a `---` line are returned whole.
    public static func section(_ lines: [String], lang: String) -> [String] {
        let parts = lines.split(omittingEmptySubsequences: false) { $0.trimmingCharacters(in: .whitespaces) == "---" }
        guard parts.count >= 2 else { return trimmed(lines) }
        return trimmed(Array(parts[lang == "id" ? 1 : 0]))
    }

    private static func trimmed(_ lines: [String]) -> [String] {
        let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.firstIndex(where: { !isBlank($0) }), let last = lines.lastIndex(where: { !isBlank($0) })
        else { return [] }
        return Array(lines[first...last])
    }
}

/// One line of release notes, for showing Markdown-ish notes without a Markdown view: `#` headings, `-`/`*` bullets,
/// blank lines and text. Inline Markdown (bold, code) stays in the text.
public enum ReleaseNoteLine: Equatable, Sendable {
    case heading(String), bullet(String), text(String), blank

    public init(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            self = .blank
        } else if trimmed.hasPrefix("#") {
            self = .heading(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            self = .bullet(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        } else {
            self = .text(trimmed)
        }
    }
}
