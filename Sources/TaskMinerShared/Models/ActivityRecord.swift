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

    // MARK: - Extended context (migration 9)

    /// URL from browser address bar (Safari/Chrome) — extracted via Accessibility.
    public var browserURL: String?
    /// AX document attribute — file path of the open document in editors/viewers.
    public var documentPath: String?
    /// AX focused element role (e.g. "AXTextField", "AXWebArea", "AXTextArea").
    public var focusedElementRole: String?

    public init(
        id: Int64? = nil,
        timestamp: Date = Date(),
        endTime: Date? = nil,
        appName: String,
        bundleId: String?,
        windowTitle: String? = nil,
        duration: TimeInterval? = nil,
        isIdle: Bool = false,
        browserURL: String? = nil,
        documentPath: String? = nil,
        focusedElementRole: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.endTime = endTime
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.duration = duration
        self.isIdle = isIdle
        self.browserURL = browserURL
        self.documentPath = documentPath
        self.focusedElementRole = focusedElementRole
    }
}
