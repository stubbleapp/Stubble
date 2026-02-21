import Foundation

public struct SharedConfiguration: Sendable {
    public let dataDirectory: URL
    public let databasePath: URL
    public let screenshotDirectory: URL
    public let settingsPath: URL

    public init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let base = appSupport.appendingPathComponent("TaskMiner")
        self.dataDirectory = base
        self.databasePath = base.appendingPathComponent("taskminer.db")
        self.screenshotDirectory = base.appendingPathComponent("screenshots")
        self.settingsPath = base.appendingPathComponent("settings.json")
    }
}
