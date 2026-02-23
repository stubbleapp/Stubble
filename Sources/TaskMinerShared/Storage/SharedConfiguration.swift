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

        // One-time migration: rename legacy database file
        let legacyDb = base.appendingPathComponent("taskminer.db")
        let fm = FileManager.default
        if fm.fileExists(atPath: legacyDb.path) && !fm.fileExists(atPath: databasePath.path) {
            try? fm.moveItem(at: legacyDb, to: databasePath)
            // Also move WAL and SHM sidecar files
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

public enum ConfigurationError: Error {
    case applicationSupportUnavailable
}
