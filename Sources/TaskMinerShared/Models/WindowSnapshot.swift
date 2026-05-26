import Foundation

/// A snapshot of visible windows on screen at a point in time.
/// Captures geometry, z-order, and ownership to understand attention distribution.
public struct WindowSnapshot: Sendable {
    public let timestamp: Date
    public let windows: [WindowInfo]

    /// Primary display bounds at capture time.
    public let displayWidth: Int
    public let displayHeight: Int

    public init(timestamp: Date = Date(), windows: [WindowInfo], displayWidth: Int, displayHeight: Int) {
        self.timestamp = timestamp
        self.windows = windows
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }

    /// The frontmost (active) window, if any.
    public var activeWindow: WindowInfo? {
        windows.first { $0.isOnScreen && $0.layer == 0 }
    }

    /// Windows sorted by z-order (front to back).
    public var windowsByZOrder: [WindowInfo] {
        windows.filter { $0.isOnScreen }.sorted { $0.layer < $1.layer }
    }

    /// Percentage of screen covered by windows (approximation).
    public var screenCoverage: Double {
        guard displayWidth > 0 && displayHeight > 0 else { return 0 }
        let totalArea = Double(displayWidth * displayHeight)
        let coveredArea = windows.filter { $0.isOnScreen }.reduce(0.0) { acc, w in
            acc + Double(w.width * w.height)
        }
        return min(1.0, coveredArea / totalArea)
    }
}

/// Information about a single window.
public struct WindowInfo: Sendable, Codable {
    /// Window ID (CGWindowID).
    public let windowId: UInt32

    /// Owning application name.
    public let appName: String

    /// Owning application bundle ID.
    public let bundleId: String?

    /// Owning process ID.
    public let pid: Int32

    /// Window title (may be empty for some windows).
    public let title: String

    /// Window layer (0 = normal, negative = below, positive = above).
    public let layer: Int32

    /// Window bounds on screen.
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    /// Whether the window is currently visible on screen.
    public let isOnScreen: Bool

    /// Window alpha (0.0 = transparent, 1.0 = opaque).
    public let alpha: Double

    public init(
        windowId: UInt32,
        appName: String,
        bundleId: String?,
        pid: Int32,
        title: String,
        layer: Int32,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        isOnScreen: Bool,
        alpha: Double
    ) {
        self.windowId = windowId
        self.appName = appName
        self.bundleId = bundleId
        self.pid = pid
        self.title = title
        self.layer = layer
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isOnScreen = isOnScreen
        self.alpha = alpha
    }

    /// Whether this is a "real" window (not a menu bar, dock, etc.).
    public var isNormalWindow: Bool {
        layer == 0 && width > 50 && height > 50 && alpha > 0.5
    }

    /// Screen area covered by this window.
    public var area: Int {
        width * height
    }

    /// Whether this window is likely the main content window (large, visible, normal layer).
    public var isMainContent: Bool {
        isNormalWindow && isOnScreen && area > 100_000
    }
}

/// Compact summary for storage/prompt injection.
public struct WindowLayoutSummary: Sendable, Codable {
    /// App name of the frontmost window.
    public let activeApp: String?

    /// Title of the frontmost window.
    public let activeTitle: String?

    /// Number of visible windows.
    public let visibleWindowCount: Int

    /// Unique apps with visible windows.
    public let visibleApps: [String]

    /// Whether the active window is full-screen.
    public let isFullScreen: Bool

    /// Whether there are side-by-side windows (split view indicator).
    public let hasSideBySide: Bool

    /// Percentage of screen covered.
    public let screenCoverage: Double

    public init(from snapshot: WindowSnapshot) {
        let normalWindows = snapshot.windows.filter { $0.isNormalWindow && $0.isOnScreen }
        let sorted = normalWindows.sorted { $0.layer < $1.layer }

        self.activeApp = sorted.first?.appName
        self.activeTitle = sorted.first?.title
        self.visibleWindowCount = normalWindows.count
        self.visibleApps = Array(Set(normalWindows.map { $0.appName })).sorted()
        self.screenCoverage = snapshot.screenCoverage

        // Detect full-screen: single window covering >90% of display
        if let first = sorted.first {
            let windowCoverage = Double(first.width * first.height) / Double(snapshot.displayWidth * snapshot.displayHeight)
            self.isFullScreen = windowCoverage > 0.9
        } else {
            self.isFullScreen = false
        }

        // Detect side-by-side: two windows each covering ~40-60% width
        if normalWindows.count >= 2 {
            let widths = normalWindows.map { Double($0.width) / Double(snapshot.displayWidth) }
            let sideBySideCount = widths.filter { $0 > 0.35 && $0 < 0.65 }.count
            self.hasSideBySide = sideBySideCount >= 2
        } else {
            self.hasSideBySide = false
        }
    }

    /// Compact string for prompt injection.
    public func asPromptContext() -> String? {
        guard visibleWindowCount > 0 else { return nil }

        var parts: [String] = []

        if let app = activeApp {
            if isFullScreen {
                parts.append("\(app) (full-screen)")
            } else {
                parts.append("\(app) active")
            }
        }

        if hasSideBySide && visibleApps.count >= 2 {
            parts.append("side-by-side: \(visibleApps.prefix(3).joined(separator: ", "))")
        } else if visibleWindowCount > 1 {
            parts.append("\(visibleWindowCount) windows visible")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
