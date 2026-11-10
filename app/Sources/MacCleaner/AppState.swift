import Foundation
import MacCleanerCore

/// App-wide state and the engine wiring: language, dry run, disk space, the `env` meta and one job per screen.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// "id" or "en". `setLang` changes it and saves it for the CLI too.
    @Published private(set) var lang: String
    @Published var dryRun = false
    @Published private(set) var disk: DiskInfo?
    /// The `env` meta: `version`, `has_brew`, `has_docker`, `has_orb`, `has_mas`, `has_fda`, … (empty until loaded).
    @Published private(set) var env: [String: String] = [:]

    /// The demo engine under `MAC_CLEANER_DEMO=1`, else the bundled script. nil when the script is missing:
    /// RootView then shows only an error.
    let engine: EngineClient?

    // One job per screen. They live here, so switching screens never stops a job or loses its results.
    private(set) lazy var cache = makeJob()
    private(set) lazy var docker = makeJob()
    private(set) lazy var apps = makeJob()
    private(set) lazy var uninstall = makeJob()
    private(set) lazy var folders = makeJob()
    private(set) lazy var updates = makeJob()
    private(set) lazy var ram = makeJob()

    /// What the job models talk to. Without a script that is its expected bundle path, so every command
    /// fails with `not_found`; RootView shows no screen in that case anyway.
    private let jobEngine: EngineClient
    private let jobs = NSHashTable<JobModel>.weakObjects()  // every job made, for anyRunning and cancelScans

    private init() {
        let saved = try? String(contentsOfFile: NSHomeDirectory() + "/.config/mac-cleaner/lang", encoding: .utf8)
        lang = UILanguage.initial(saved: saved, preferred: Locale.preferredLanguages)
        engine = Self.makeEngine()
        jobEngine = engine ?? ScriptEngine(scriptURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/mac-cleaner.command"))
    }

    private static func makeEngine() -> EngineClient? {
        if EngineLocator.isDemo {
            return DemoEngine(fixtures: (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("demo"))
        }
        if let script = EngineLocator.scriptURL() { return ScriptEngine(scriptURL: script) }
        return nil
    }

    /// True while any job, a screen's or one from `makeJob()`, runs an action. Quitting waits for those.
    var anyRunning: Bool { jobs.allObjects.contains { $0.phase == .running } }

    /// A new job model that runs with the current language and dry-run setting, for work besides a
    /// screen's own job (e.g. the uninstall sheet). It counts for `anyRunning` and `cancelScans()`.
    func makeJob() -> JobModel {
        let job = JobModel(engine: jobEngine, options: { [unowned self] in EngineOptions(lang: lang, dryRun: dryRun) })
        jobs.add(job)
        return job
    }

    /// Cancels every scan in progress (on quit). Actions keep running.
    func cancelScans() {
        jobs.allObjects.forEach { $0.cancel() }
    }

    /// Loads the `env` meta (on launch).
    func loadEnv() async {
        let job = makeJob()
        await job.scan(["env"])
        if job.phase == .done { env = job.meta }
    }

    func refreshDisk() async {
        let job = makeJob()
        await job.scan(["disk"])
        if let disk = job.disk { self.disk = disk }
    }

    /// Switches the language and saves it for the CLI (`set-lang`). The UI switches even if saving fails.
    func setLang(_ newLang: String) async {
        guard newLang != lang else { return }
        await makeJob().run(["set-lang", newLang])
        lang = newLang
    }
}
