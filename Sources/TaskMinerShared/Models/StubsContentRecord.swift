import Foundation

/// Persistence record for AI-generated stubs page content.
/// Stores one record per date — today gets forward-looking stubs, past days get retrospective summaries.
public struct StubsContentRecord: Sendable {
    public let id: Int64?
    public let date: String                 // "yyyy-MM-dd"
    public let greetingContext: String
    public let daySummary: String?
    public let questionsJson: String        // JSON-encoded [String]
    public let recommendationsJson: String  // JSON-encoded [[String: Any]]
    public let generatedAt: Date

    // Day wrap metrics (persisted for past days)
    public let focusTimeSeconds: Int?
    public let meetingTimeSeconds: Int?
    public let projectCount: Int?

    public init(
        id: Int64? = nil,
        date: String,
        greetingContext: String,
        daySummary: String? = nil,
        questionsJson: String = "[]",
        recommendationsJson: String = "[]",
        generatedAt: Date = Date(),
        focusTimeSeconds: Int? = nil,
        meetingTimeSeconds: Int? = nil,
        projectCount: Int? = nil
    ) {
        self.id = id
        self.date = date
        self.greetingContext = greetingContext
        self.daySummary = daySummary
        self.questionsJson = questionsJson
        self.recommendationsJson = recommendationsJson
        self.generatedAt = generatedAt
        self.focusTimeSeconds = focusTimeSeconds
        self.meetingTimeSeconds = meetingTimeSeconds
        self.projectCount = projectCount
    }
}
