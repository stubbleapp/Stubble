import Foundation

public enum ScreenshotTrigger: String, Sendable {
    case appSwitch = "app_switch"
    case titleChange = "title_change"
    case periodic = "periodic"
    case manual = "manual"
}

public struct ScreenshotRecord: Identifiable, Hashable, Sendable {
    public var id: Int64?
    public let timestamp: Date
    public let filePath: String
    public let fileSize: Int?
    public let activityId: Int64?
    public let trigger: ScreenshotTrigger
    public let ocrText: String?

    public init(
        id: Int64? = nil,
        timestamp: Date = Date(),
        filePath: String,
        fileSize: Int? = nil,
        activityId: Int64?,
        trigger: ScreenshotTrigger,
        ocrText: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.filePath = filePath
        self.fileSize = fileSize
        self.activityId = activityId
        self.trigger = trigger
        self.ocrText = ocrText
    }
}
