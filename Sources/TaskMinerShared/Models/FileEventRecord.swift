import Foundation

/// A single file system change event captured by FSEvents monitoring.
public struct FileEventRecord: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let timestamp: Date
    public let filePath: String
    public let eventType: String  // "created" | "modified" | "removed" | "renamed"
    public let activityId: Int64?

    public init(id: Int64, timestamp: Date, filePath: String,
                eventType: String, activityId: Int64? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.filePath = filePath
        self.eventType = eventType
        self.activityId = activityId
    }

    /// The file name component (last path segment) for compact display.
    public var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    /// The parent directory for context display.
    public var directory: String {
        (filePath as NSString).deletingLastPathComponent
    }
}
