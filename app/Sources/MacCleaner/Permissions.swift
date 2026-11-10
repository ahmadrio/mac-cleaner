import Foundation

/// The macOS privacy permissions Mac Cleaner may need, each with its System Settings panel.
enum PermissionKind {
    /// Finder control, to move items to the Trash and to empty it (`@@error finder_denied`).
    case automation
    /// To size ~/Library/Containers and the Trash (`bigdata-scan` meta `fda=0`).
    case fullDiskAccess
    /// So `brew upgrade --cask` and DMG updates may replace apps in /Applications.
    case appManagement

    var settingsURL: URL {
        let pane = switch self {
        case .automation: "Privacy_Automation"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .appManagement: "Privacy_AppBundles"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!
    }

    /// The name as System Settings shows it, with the English name in Indonesian so both can be found.
    @MainActor var title: String {
        switch self {
        case .automation: L("Otomatisasi (Automation) untuk Finder", "Automation for Finder")
        case .fullDiskAccess: L("Akses Disk Penuh (Full Disk Access)", "Full Disk Access")
        case .appManagement: L("Manajemen App (App Management)", "App Management")
        }
    }
}
