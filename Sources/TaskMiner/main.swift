import Foundation
import AppKit
import TaskMinerShared

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

// MARK: - Check permissions

let hasAccessibility = Permissions.checkAccessibility(promptIfNeeded: true)
let hasScreenRecording = Permissions.checkScreenRecording()

if !hasAccessibility {
    Logger.error("Accessibility permission not granted")
    Permissions.printGuidance()
    exit(1)
}

if !hasScreenRecording {
    Logger.warning("Screen Recording permission not granted — screenshots will be disabled")
    Logger.warning("Grant permission in System Settings → Privacy & Security → Screen Recording")
}

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
