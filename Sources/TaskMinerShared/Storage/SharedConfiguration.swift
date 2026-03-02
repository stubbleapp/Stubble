import Foundation

public struct SharedConfiguration: Sendable {
    public let dataDirectory: URL
    public let databasePath: URL
    public let screenshotDirectory: URL
    public let settingsPath: URL
    public let memoryPath: URL

    public init() throws {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw ConfigurationError.applicationSupportUnavailable
        }
        let base = appSupport.appendingPathComponent("Stubble")
        self.dataDirectory = base
        self.databasePath = base.appendingPathComponent("stubble.db")
        self.screenshotDirectory = base.appendingPathComponent("screenshots")
        self.settingsPath = base.appendingPathComponent("settings.json")
        self.memoryPath = base.appendingPathComponent("memory.json")

        // Ensure data directory exists before any file operations
        let fm = FileManager.default
        if !fm.fileExists(atPath: base.path) {
            try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        // One-time migration: rename legacy database file.
        // Uses an exclusive file lock to prevent a race if Dashboard and Daemon
        // both initialize at the same instant.
        let legacyDb = base.appendingPathComponent("taskminer.db")
        if fm.fileExists(atPath: legacyDb.path) && !fm.fileExists(atPath: databasePath.path) {
            let lockPath = base.appendingPathComponent(".migration.lock")
            fm.createFile(atPath: lockPath.path, contents: nil)
            if let lockFd = FileHandle(forWritingAtPath: lockPath.path) {
                flock(lockFd.fileDescriptor, LOCK_EX)
                defer {
                    flock(lockFd.fileDescriptor, LOCK_UN)
                    lockFd.closeFile()
                    try? fm.removeItem(at: lockPath)
                }
                // Re-check after acquiring lock (another process may have already migrated)
                if fm.fileExists(atPath: legacyDb.path) && !fm.fileExists(atPath: databasePath.path) {
                    try? fm.moveItem(at: legacyDb, to: databasePath)
                    for suffix in ["-wal", "-shm"] {
                        let old = base.appendingPathComponent("taskminer.db\(suffix)")
                        let new = base.appendingPathComponent("stubble.db\(suffix)")
                        if fm.fileExists(atPath: old.path) {
                            try? fm.moveItem(at: old, to: new)
                        }
                    }
                }
            }
        }
    }
}

public enum ConfigurationError: Error {
    case applicationSupportUnavailable
}
