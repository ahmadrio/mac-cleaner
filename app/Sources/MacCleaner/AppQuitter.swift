import AppKit
import MacCleanerCore

/// Quits running apps the polite way (like choosing Quit in each), never forcibly.
@MainActor
enum AppQuitter {
    /// Asks every running copy of each app (by bundle path) to quit, then waits up to 15 s for them to go.
    /// Returns, per path, whether the app is no longer running; an app may refuse, e.g. to save a document.
    /// Mac Cleaner itself is never asked.
    ///
    /// Demo mode (`MAC_CLEANER_DEMO=1`) is simulated here, for every screen that quits apps: nothing is
    /// terminated and every app counts as quit. Demo fixture paths can match apps really installed on the Mac.
    static func quit(appPaths: [String]) async -> [String: Bool] {
        if EngineLocator.isDemo { return Dictionary(appPaths.map { ($0, true) }, uniquingKeysWith: { first, _ in first }) }
        for path in appPaths { running(path).forEach { $0.terminate() } }
        let deadline = ContinuousClock.now + .seconds(15)
        while appPaths.contains(where: { !running($0).isEmpty }), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
        }
        return Dictionary(appPaths.map { ($0, running($0).isEmpty) }, uniquingKeysWith: { first, _ in first })
    }

    /// The paths among `appPaths` that have a running copy (read-only, nothing is asked to quit), in order.
    /// Demo mode reports none, like `quit` simulates: fixture paths can match apps really installed.
    static func runningPaths(among appPaths: [String]) -> [String] {
        if EngineLocator.isDemo { return [] }
        return appPaths.filter { !running($0).isEmpty }
    }

    private static func running(_ path: String) -> [NSRunningApplication] {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter {
            $0 != NSRunningApplication.current && $0.bundleURL?.standardizedFileURL.path == path
        }
    }
}
