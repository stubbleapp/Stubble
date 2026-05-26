import Foundation

/// Persisted Day tab narrative and wrap metrics (one row per calendar day).
/// Replaces the former `stubs_content` path for timeline day summaries.
public struct DayWrapRecord: Sendable {
    public let date: String // "yyyy-MM-dd"
    public let summary: String?
    public let focusTimeSeconds: Int?
    public let meetingTimeSeconds: Int?
    public let projectCount: Int?
    public let updatedAt: Date

    public init(
        date: String,
        summary: String?,
        focusTimeSeconds: Int?,
        meetingTimeSeconds: Int?,
        projectCount: Int?,
        updatedAt: Date = Date()
    ) {
        self.date = date
        self.summary = summary
        self.focusTimeSeconds = focusTimeSeconds
        self.meetingTimeSeconds = meetingTimeSeconds
        self.projectCount = projectCount
        self.updatedAt = updatedAt
    }
}
