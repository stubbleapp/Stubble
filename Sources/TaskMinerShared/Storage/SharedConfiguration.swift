import Foundation

public struct SharedConfiguration: Sendable {
    public let dataDirectory: URL
    public let databasePath: URL
    public let screenshotDirectory: URL
    public let settingsPath: URL

    public init() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            fatalError("Application Support directory is not available. TaskMiner cannot run without it.")
        }
        let base = appSupport.appendingPathComponent("TaskMiner")
        self.dataDirectory = base
        self.databasePath = base.appendingPathComponent("taskminer.db")
        self.screenshotDirectory = base.appendingPathComponent("screenshots")
        self.settingsPath = base.appendingPathComponent("settings.json")
    }
}

public enum ConfigurationError: Error {
    case applicationSupportUnavailable
}
