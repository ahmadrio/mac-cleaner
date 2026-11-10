import Foundation

/// Path display helpers.
public enum PathFormat {
    /// Shows `home` as `~`, like `tilde` in mac-cleaner.command. Only a whole leading folder matches:
    /// `/Users/anabel/x` is not under `/Users/ana`. The home folder itself becomes `~`.
    public static func tilde(_ path: String, home: String) -> String {
        var home = home
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
