import Foundation
import AppKit
import TaskMinerShared

/// Entry point for the background monitoring daemon.
/// Called from the Dashboard binary when launched in daemon mode (--daemon flag
/// or when the process name is "StubbleDaemon"). Using the same binary for both
/// the GUI and the daemon means macOS permissions (Screen Recording, Accessibility)
/// only need to be granted once.
public enum DaemonMain {
    /// File descriptor for the PID lock — held open for the daemon's entire lifetime.
    private static var lockFd: Int32 = -1
    /// Path to the PID file — stored as static for atexit cleanup.
    private static var pidFilePath: String = ""

    public static func run() -> Never {
        // Hide from Dock and app switcher — the daemon is a background-only process.
        // Must be set before anything triggers NSApplication.shared creation
        // (NSWorkspace, AXObserver, etc.) to prevent a second Dock icon.
        NSApplication.shared.setActivationPolicy(.prohibited)

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

        // MARK: - Singleton lock (prevent multiple daemons)

        pidFilePath = config.dataDirectory.appendingPathComponent("daemon.pid").path
        lockFd = open(pidFilePath, O_WRONLY | O_CREAT, 0o600)
        guard lockFd >= 0 else {
            Logger.error("Cannot open PID file: \(String(cString: strerror(errno)))")
            exit(1)
        }
        guard flock(lockFd, LOCK_EX | LOCK_NB) == 0 else {
            Logger.info("Another daemon is already running — exiting")
            close(lockFd)
            exit(0)
        }
        // Write our PID so operators can identify the running daemon
        ftruncate(lockFd, 0)
        let pidStr = "\(ProcessInfo.processInfo.processIdentifier)\n"
        pidStr.withCString { ptr in _ = write(lockFd, ptr, strlen(ptr)) }
        // lockFd stays open — the OS releases the lock when the process exits.
        // atexit ensures cleanup even if initialization below fails (exit(1) paths).
        atexit {
            if DaemonMain.lockFd >= 0 {
                close(DaemonMain.lockFd)
                DaemonMain.lockFd = -1
            }
            if !DaemonMain.pidFilePath.isEmpty {
                unlink(DaemonMain.pidFilePath)
            }
        }

        // NOTE: No permission checks here. The Dashboard's setup wizard handles prompting.
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
            // PID lock cleanup is handled by atexit
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
    }
}
