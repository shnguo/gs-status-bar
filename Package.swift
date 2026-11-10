// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GSStatusBar",
    platforms: [.macOS(.v14)],
    targets: [
        // Data model and readers for Codex / Claude Code usage. No UI, fully testable.
        .target(
            name: "UsageCore",
            path: "Sources/UsageCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu bar app.
        .executableTarget(
            name: "GSStatusBar",
            dependencies: ["UsageCore"],
            path: "Sources/GSStatusBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
