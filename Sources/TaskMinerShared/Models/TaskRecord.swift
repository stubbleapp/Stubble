import Foundation

public struct TaskRecord: Identifiable, Hashable, Sendable {
    public let id: Int64?
    public let date: String
    public let startTime: Date
    public let endTime: Date
    public let title: String
    public let description: String
    public let appNames: String
    public let confidence: Double
    /// JSON array of URL/path strings extracted by AI from OCR/activity data.
    public let relevantLinks: String
    /// Actual active time in seconds (sum of constituent activity block durations).
    /// When nil, falls back to endTime - startTime.
    public let activeDuration: TimeInterval?

    public init(
        id: Int64? = nil,
        date: String,
        startTime: Date,
        endTime: Date,
        title: String,
        description: String,
        appNames: String = "[]",
        confidence: Double = 0.0,
        relevantLinks: String = "[]",
        activeDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
        self.description = description
        self.appNames = appNames
        self.confidence = confidence
        self.relevantLinks = relevantLinks
        self.activeDuration = activeDuration
    }

    /// The best available duration for this task.
    /// Uses AI-reported active duration when available, otherwise span time.
    public var duration: TimeInterval {
        activeDuration ?? endTime.timeIntervalSince(startTime)
    }

    public var appNamesList: [String] {
        guard let data = appNames.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return arr
    }

    /// Parsed links from the relevantLinks JSON.
    public var linksList: [ExtractedLink] {
        LinkExtractor.linksFromJSON(relevantLinks)
    }
}
