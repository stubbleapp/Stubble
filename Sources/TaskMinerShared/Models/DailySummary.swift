import Foundation

public struct DailySummary: Identifiable, Hashable, Sendable {
    public let id: Int64?
    public let date: String
    public let totalActiveSeconds: Double
    public let totalIdleSeconds: Double
    public let appUsageJSON: String
    public let topWindowsJSON: String
    public let screenshotCount: Int
    public let generatedAt: Date?

    public init(
        id: Int64? = nil,
        date: String,
        totalActiveSeconds: Double,
        totalIdleSeconds: Double,
        appUsageJSON: String = "{}",
        topWindowsJSON: String = "[]",
        screenshotCount: Int = 0,
        generatedAt: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.totalActiveSeconds = totalActiveSeconds
        self.totalIdleSeconds = totalIdleSeconds
        self.appUsageJSON = appUsageJSON
        self.topWindowsJSON = topWindowsJSON
        self.screenshotCount = screenshotCount
        self.generatedAt = generatedAt
    }
}
