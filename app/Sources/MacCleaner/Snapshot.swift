import AppKit
import MacCleanerCore

/// A hidden dev mode that renders the README screenshots from the demo fixtures:
///
///     MAC_CLEANER_DEMO=1 MAC_CLEANER_SNAPSHOT_DIR=/tmp/shots "build/Mac Cleaner.app/Contents/MacOS/MacCleaner"
///
/// It shows each screen in turn, runs that screen's demo scan, waits for it, renders the whole window (title bar,
/// toolbar and content) to `<dir>/gui-<screen>.png`, then quits. The window has a fixed size, dark appearance and
/// English text; the language file and the app's saved settings are left as they were. Without `MAC_CLEANER_DEMO=1`
/// the variable is ignored, so it never runs against the real engine, and it only scans. The app draws its own window
/// into a bitmap, so no Screen Recording permission is needed.
@MainActor
enum Snapshot {
    /// `MAC_CLEANER_SNAPSHOT_DIR`, honoured only together with `MAC_CLEANER_DEMO=1`.
    static let directory: URL? = {
        guard EngineLocator.isDemo, let path = ProcessInfo.processInfo.environment["MAC_CLEANER_SNAPSHOT_DIR"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    private static let windowSize = NSSize(width: 1040, height: 720)

    /// The app's saved defaults before the run; AppKit still saves the window and sidebar frames, so they are put back.
    private static var savedDefaults: [String: Any]?

    /// Makes the window open at the capture size (called before it exists). A window resized after launch can come
    /// out with a blank toolbar pop-up, so the frame goes into the volatile argument domain instead, which overrides
    /// the saved window frame.
    static func prepare() {
        guard directory != nil else { return }
        if let id = Bundle.main.bundleIdentifier { savedDefaults = UserDefaults.standard.persistentDomain(forName: id) ?? [:] }
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let origin = NSPoint(x: screen.midX - windowSize.width / 2, y: screen.midY - windowSize.height / 2)
        let frame = [origin.x, origin.y, windowSize.width, windowSize.height, screen.minX, screen.minY, screen.width, screen.height]
            .map { String(Int($0)) }.joined(separator: " ")
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["NSWindow Frame main"] = frame  // "main" is the id of the app's Window scene
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// Captures every screen; `show` selects one in the sidebar. Ends the app.
    static func run(into directory: URL, appState: AppState, show: (Screen) -> Void) async {
        defer {
            if let id = Bundle.main.bundleIdentifier, let savedDefaults {
                UserDefaults.standard.setPersistentDomain(savedDefaults, forName: id)
            }
            NSApp.terminate(nil)
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            fail("no window to capture")
            return
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window.setFrameAutosaveName("")  // the fixed size must not become the user's saved window size
        window.setContentSize(windowSize)  // normally a no-op after `prepare()`
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fail(error.localizedDescription)
            return
        }
        for screen in Screen.allCases {
            show(screen)
            await load(screen, appState)
            try? await Task.sleep(for: .milliseconds(800))  // let the tables fill and the log scroll
            let file = directory.appendingPathComponent("gui-\(screen).png")
            do {
                try capture(window, to: file)
                print("wrote \(file.path)")
            } catch {
                fail("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Runs the screen's scan, or waits for the one the screen starts by itself when it appears.
    private static func load(_ screen: Screen, _ appState: AppState) async {
        switch screen {
        case .cache: await appState.cache.scan(["caches-scan"])
        case .docker: await wait { appState.docker.phase == .done && appState.dockerList.phase == .done }
        case .apps: await appState.apps.scan(["apps-scan", String(ScanDays.defaultDays)])
        case .uninstall: await wait { appState.uninstall.phase == .done }
        case .folders: await appState.folders.scan(["bigdata-scan"])
        case .updates: await appState.updates.scan(["updates-scan"])
        case .ram: await appState.ram.scan(["ram-scan"])
        }
    }

    private static func wait(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(15)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// Draws the window's frame view (title bar, toolbar and content) at the screen's scale into a PNG.
    /// `cacheDisplay(in:to:)` leaves the toolbar's language pop-up blank, so the bitmap is filled by rendering the
    /// view's layer tree instead, which draws every control.
    private static func capture(_ window: NSWindow, to file: URL) throws {
        guard let view = window.contentView?.superview, let layer = view.layer,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.fileWriteUnknown) }
        layer.render(in: context.cgContext)  // the context already maps the view's points to the rep's pixels
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: file)
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
    }
}
