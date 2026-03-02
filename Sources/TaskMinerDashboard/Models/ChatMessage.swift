import Foundation
import Observation
import TaskMinerShared

@Observable
final class ChatMessage: Identifiable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    /// Database row ID, set after persisting.
    var dbId: Int64?

    init(role: Role, content: String, timestamp: Date = Date(), isStreaming: Bool = false, dbId: Int64? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.dbId = dbId
    }

    /// Create from a persisted database record.
    convenience init(from record: ChatMessageRecord) {
        let role: Role = record.role == "assistant" ? .assistant : .user
        self.init(role: role, content: record.content, timestamp: record.timestamp, dbId: record.id)
    }

    /// Convert to a persistence record for a given date string.
    func toRecord(threadId: Int64, date: String) -> ChatMessageRecord {
        ChatMessageRecord(
            id: dbId,
            threadId: threadId,
            date: date,
            role: role.dbString,
            content: content,
            timestamp: timestamp
        )
    }

    enum Role {
        case user
        case assistant

        var dbString: String {
            switch self {
            case .user: return "user"
            case .assistant: return "assistant"
            }
        }
    }
}
