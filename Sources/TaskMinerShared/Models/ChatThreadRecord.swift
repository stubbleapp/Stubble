import Foundation

/// Persistence-layer model for chat threads stored in SQLite.
public struct ChatThreadRecord: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let title: String
    public let summary: String
    /// Optional day context captured when the thread was created/anchored.
    public let contextDate: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let lastMessageAt: Date?
    public let messageCount: Int
    public let isArchived: Bool

    public init(
        id: Int64,
        title: String,
        summary: String,
        contextDate: String?,
        createdAt: Date,
        updatedAt: Date,
        lastMessageAt: Date?,
        messageCount: Int,
        isArchived: Bool
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.contextDate = contextDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
        self.isArchived = isArchived
    }
}
