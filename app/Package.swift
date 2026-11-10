// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacCleaner",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MacCleanerCore"),
        .executableTarget(name: "MacCleaner", dependencies: ["MacCleanerCore"]),
        .testTarget(name: "MacCleanerCoreTests", dependencies: ["MacCleanerCore"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v5]
)
