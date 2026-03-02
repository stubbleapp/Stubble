import Foundation
import Observation
import TaskMinerShared

@Observable
final class ChatThread: Identifiable {
    let id: Int64
    var title: String
    var summary: String
    var contextDate: String?
    let createdAt: Date
    var updatedAt: Date
    var lastMessageAt: Date?
    var messageCount: Int
    var isArchived: Bool

    init(from record: ChatThreadRecord) {
        self.id = record.id
        self.title = record.title
        self.summary = record.summary
        self.contextDate = record.contextDate
        self.createdAt = record.createdAt
        self.updatedAt = record.updatedAt
        self.lastMessageAt = record.lastMessageAt
        self.messageCount = record.messageCount
        self.isArchived = record.isArchived
    }
}
