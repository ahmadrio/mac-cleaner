import AppKit

/// Quits running apps the polite way (like choosing Quit in each), never forcibly.
@MainActor
enum AppQuitter {
    /// Asks every running copy of each app (by bundle path) to quit, then waits up to 15 s for them to go.
    /// Returns, per path, whether the app is no longer running; an app may refuse, e.g. to save a document.
    /// Mac Cleaner itself is never asked.
    static func quit(appPaths: [String]) async -> [String: Bool] {
        for path in appPaths { running(path).forEach { $0.terminate() } }
        let deadline = ContinuousClock.now + .seconds(15)
        while appPaths.contains(where: { !running($0).isEmpty }), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
        }
        return Dictionary(appPaths.map { ($0, running($0).isEmpty) }, uniquingKeysWith: { first, _ in first })
    }

    private static func running(_ path: String) -> [NSRunningApplication] {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter {
            $0 != NSRunningApplication.current && $0.bundleURL?.standardizedFileURL.path == path
        }
    }
}
