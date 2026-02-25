import Foundation

/// Persistence-layer model for chat messages stored in SQLite.
/// Follows the same pattern as `TaskRecord` and `ProjectActivityRecord`.
public struct ChatMessageRecord: Identifiable, Hashable, Sendable {
    public let id: Int64?
    /// Date string in "yyyy-MM-dd" format — scopes the conversation to a day.
    public let date: String
    /// "user" or "assistant"
    public let role: String
    public let content: String
    public let timestamp: Date

    public init(
        id: Int64? = nil,
        date: String,
        role: String,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.date = date
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}
