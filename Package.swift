// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TaskMiner",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.0"),
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK", exact: "2.11.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
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
                .linkedLibrary("sqlite3"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreServices"),
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
                "TaskMinerMCP",
                "Sparkle",
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/TaskMinerDashboard",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // MCP server library (exposes Stubble data to AI agents)
        .target(
            name: "TaskMinerMCP",
            dependencies: ["TaskMinerShared"],
            path: "Sources/TaskMinerMCP"
        ),
        // MCP server executable (stdio transport for AI agents)
        .executableTarget(
            name: "stubble-mcp",
            dependencies: ["TaskMinerMCP"],
            path: "Sources/StubbleMCP"
        ),
        // Unit tests for shared library
        .testTarget(
            name: "TaskMinerSharedTests",
            dependencies: ["TaskMinerShared"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // Unit tests for dashboard view models and processing
        .testTarget(
            name: "TaskMinerDashboardTests",
            dependencies: ["TaskMinerDashboard", "TaskMinerShared"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
    ]
)
