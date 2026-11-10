import Foundation

/// The UI language, "id" or "en", chosen the way mac-cleaner.command chooses it.
public enum UILanguage {
    /// The script's `case "$UI_LANG" in id*|ID*|in|in_*|in-*|indo*|Indo*) … id`: everything else is "en".
    public static func normalize(_ code: String) -> String {
        let indonesian = ["id", "ID", "in_", "in-", "indo", "Indo"].contains { code.hasPrefix($0) } || code == "in"
        return indonesian ? "id" : "en"
    }

    /// The choice saved by the CLI or the app (`~/.config/mac-cleaner/lang`) wins, then the first
    /// preferred macOS language, then English.
    public static func initial(saved: String?, preferred: [String]) -> String {
        if let saved = saved?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty { return normalize(saved) }
        return preferred.first.map(normalize) ?? "en"
    }
}
