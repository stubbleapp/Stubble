import Foundation

/// Database-backed record for a project activity (AI-clustered group of tasks).
public struct ProjectActivityRecord: Identifiable, Hashable, Sendable {
    public let id: Int64?
    public let date: String
    public let name: String
    public let summary: String
    public let totalDuration: TimeInterval
    public let appNames: String       // JSON array
    public let taskTitles: String      // JSON array
    public let startTime: Date
    public let endTime: Date
    public let colorIndex: Int

    public init(
        id: Int64? = nil,
        date: String,
        name: String,
        summary: String,
        totalDuration: TimeInterval,
        appNames: String = "[]",
        taskTitles: String = "[]",
        startTime: Date,
        endTime: Date,
        colorIndex: Int = 0
    ) {
        self.id = id
        self.date = date
        self.name = name
        self.summary = summary
        self.totalDuration = totalDuration
        self.appNames = appNames
        self.taskTitles = taskTitles
        self.startTime = startTime
        self.endTime = endTime
        self.colorIndex = colorIndex
    }

    /// Parse the JSON app names array.
    public var appNamesList: [String] {
        guard let data = appNames.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }

    /// Parse the JSON task titles array.
    public var taskTitlesList: [String] {
        guard let data = taskTitles.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }
}
