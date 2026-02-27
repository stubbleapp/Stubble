import Foundation

/// A meeting record imported from Granola's local cache, containing notes and transcript data.
public struct GranolaMeetingRecord: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let granolaId: String          // Granola document UUID
    public let title: String
    public let meetingDate: String         // yyyy-MM-dd
    public let startTime: Date
    public let endTime: Date
    public let duration: TimeInterval      // seconds
    public let attendeesJson: String       // JSON array of {name, email}
    public let organizer: String?
    public let notesPlain: String?
    public let transcriptText: String?     // Pre-formatted: "[HH:mm:ss] You: ..." / "[HH:mm:ss] Other: ..."
    public let summary: String?
    public let meetingURL: String?
    public let sourceUpdatedAt: String     // Granola's updated_at (change detection)
    public let importedAt: Date

    public init(id: Int64 = 0, granolaId: String, title: String, meetingDate: String,
                startTime: Date, endTime: Date, duration: TimeInterval,
                attendeesJson: String = "[]", organizer: String? = nil,
                notesPlain: String? = nil, transcriptText: String? = nil,
                summary: String? = nil, meetingURL: String? = nil,
                sourceUpdatedAt: String, importedAt: Date = Date()) {
        self.id = id
        self.granolaId = granolaId
        self.title = title
        self.meetingDate = meetingDate
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.attendeesJson = attendeesJson
        self.organizer = organizer
        self.notesPlain = notesPlain
        self.transcriptText = transcriptText
        self.summary = summary
        self.meetingURL = meetingURL
        self.sourceUpdatedAt = sourceUpdatedAt
        self.importedAt = importedAt
    }

    // MARK: - Computed Helpers

    /// Parse attendee names from the stored JSON array.
    public var attendeeNames: [String] {
        guard let data = attendeesJson.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return []
        }
        return arr.compactMap { $0["name"] ?? $0["email"] }
    }

    /// Number of attendees.
    public var attendeeCount: Int {
        guard let data = attendeesJson.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return 0
        }
        return arr.count
    }

    /// Duration formatted for display (e.g. "45 min", "1h 20m").
    public var formattedDuration: String {
        let mins = Int(duration / 60)
        if mins < 60 { return "\(mins) min" }
        let h = mins / 60
        let m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// Transcript truncated for AI prompt inclusion.
    public func transcriptForPrompt(maxChars: Int = 2000) -> String? {
        guard let text = transcriptText, !text.isEmpty else { return nil }
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars)) + "\n[...transcript truncated]"
    }

    /// Notes truncated for AI prompt inclusion.
    public func notesForPrompt(maxChars: Int = 2000) -> String? {
        guard let text = notesPlain, !text.isEmpty else { return nil }
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars)) + "\n[...notes truncated]"
    }
}
