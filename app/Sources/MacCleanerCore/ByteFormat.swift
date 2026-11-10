import Foundation

/// Mirrors `hsize` in mac-cleaner.command: sizes are kilobytes.
public enum ByteFormat {
    public static func string(kb: Int) -> String {
        if kb < 0 { return "?" }
        if kb >= 1_048_576 { return String(format: "%.1f GB", Double(kb) / 1_048_576) }
        if kb >= 1024 { return String(format: "%.0f MB", Double(kb) / 1024) }
        return String(format: "%d KB", kb)
    }
}
