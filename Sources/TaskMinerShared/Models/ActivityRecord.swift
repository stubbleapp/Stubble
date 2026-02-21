import Foundation

public struct ActivityRecord: Identifiable, Hashable, Sendable {
    public var id: Int64?
    public let timestamp: Date
    public var endTime: Date?
    public let appName: String
    public let bundleId: String?
    public var windowTitle: String?
    public var duration: TimeInterval?
    public var isIdle: Bool

    public init(
        id: Int64? = nil,
        timestamp: Date = Date(),
        endTime: Date? = nil,
        appName: String,
        bundleId: String?,
        windowTitle: String? = nil,
        duration: TimeInterval? = nil,
        isIdle: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.endTime = endTime
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.duration = duration
        self.isIdle = isIdle
    }
}
