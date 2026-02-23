import Foundation
import AppKit
import TaskMinerShared

// MARK: - Logging

Logger.enableFileLogging()

// MARK: - Configuration

var config: Configuration
do {
    var c = try Configuration()
    c.parseArguments()
    config = c
} catch {
    Logger.error("Configuration failed: \(error.localizedDescription)")
    exit(1)
}

// MARK: - Create directories

do {
    try config.ensureDirectories()
} catch {
    Logger.error("Failed to create data directories: \(error)")
    exit(1)
}

// NOTE: No permission checks here. The Dashboard's setup wizard handles prompting.
// Calling CGWindowListCreateImage or AXIsProcessTrustedWithOptions from the daemon
// triggers macOS permission dialogs after every Sparkle update (binary hash changes).
// The daemon gracefully handles missing permissions at runtime:
//   - No accessibility → window titles will be empty
//   - No screen recording → screenshots return nil (handled in takeScreenshot)

// MARK: - Open database

let db: DatabaseManager
do {
    db = try DatabaseManager(path: config.databasePath)
    Logger.info("Database opened: \(config.databasePath.path)")
} catch {
    Logger.error("Failed to open database: \(error)")
    exit(1)
}

// MARK: - Create app delegate

let appDelegate: AppDelegate
do {
    appDelegate = try AppDelegate(config: config, db: db)
} catch {
    Logger.error("Failed to initialize: \(error)")
    exit(1)
}

// MARK: - Signal handling for graceful shutdown

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let shutdownHandler: () -> Void = {
    appDelegate.shutdown()
    CFRunLoopStop(CFRunLoopGetMain())
}

sigintSource.setEventHandler(handler: shutdownHandler)
sigtermSource.setEventHandler(handler: shutdownHandler)

sigintSource.resume()
sigtermSource.resume()

// MARK: - Start monitoring and run

appDelegate.start()

// Run the main run loop — required for NSWorkspace notifications and AXObserver
CFRunLoopRun()

exit(0)
