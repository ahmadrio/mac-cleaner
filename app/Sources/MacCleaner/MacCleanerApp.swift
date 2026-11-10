import SwiftUI
import MacCleanerCore

@main
struct MacCleanerApp: App {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text("Mac Cleaner").font(.largeTitle)
                Text(version).foregroundStyle(.secondary)
            }
            .frame(minWidth: 320, minHeight: 200)
        }
    }
}
