// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TaskMiner",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
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
        .executableTarget(
            name: "TaskMiner",
            dependencies: ["TaskMinerShared"],
            path: "Sources/TaskMiner",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "TaskMinerDashboard",
            dependencies: [
                "TaskMinerShared",
                "Sparkle",
            ],
            path: "Sources/TaskMinerDashboard",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
