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

    public init(
        id: Int64? = nil,
        date: String,
        greetingContext: String,
        daySummary: String? = nil,
        questionsJson: String = "[]",
        recommendationsJson: String = "[]",
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.greetingContext = greetingContext
        self.daySummary = daySummary
        self.questionsJson = questionsJson
        self.recommendationsJson = recommendationsJson
        self.generatedAt = generatedAt
    }
}
