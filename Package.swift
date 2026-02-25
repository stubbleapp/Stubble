// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TaskMiner",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "TaskMinerShared",
            path: "Sources/TaskMinerShared",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security")
            ]
        ),
        // Background monitoring daemon (library so both Dashboard and CLI can embed it)
        .target(
            name: "TaskMinerDaemon",
            dependencies: ["TaskMinerShared"],
            path: "Sources/TaskMiner",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // Standalone CLI wrapper (for `swift run TaskMiner`)
        .executableTarget(
            name: "TaskMiner",
            dependencies: ["TaskMinerDaemon"],
            path: "Sources/TaskMinerCLI"
        ),
        // SwiftUI dashboard (also embeds the daemon — single binary for permissions)
        .executableTarget(
            name: "TaskMinerDashboard",
            dependencies: [
                "TaskMinerShared",
                "TaskMinerDaemon",
                "Sparkle",
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
            ],
            path: "Sources/TaskMinerDashboard",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // Unit tests for shared library
        .testTarget(
            name: "TaskMinerSharedTests",
            dependencies: ["TaskMinerShared"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
    ]
)
