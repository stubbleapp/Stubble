import Foundation
import AppKit
import CoreGraphics
import TaskMinerShared

/// Captures window geometry and z-order using CGWindowListCopyWindowInfo.
/// Provides a snapshot of visible windows for attention distribution analysis.
final class WindowGeometryCapture {

    /// Capture a snapshot of all on-screen windows.
    func captureSnapshot() -> WindowSnapshot? {
        // Get the main display bounds
        guard let mainScreen = NSScreen.main else { return nil }
        let displayWidth = Int(mainScreen.frame.width)
        let displayHeight = Int(mainScreen.frame.height)

        // Get window list info for all on-screen windows
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return nil
        }

        var windows: [WindowInfo] = []

        for windowDict in windowInfoList {
            guard let windowId = windowDict[kCGWindowNumber] as? UInt32,
                  let pid = windowDict[kCGWindowOwnerPID] as? Int32,
                  let ownerName = windowDict[kCGWindowOwnerName] as? String,
                  let boundsDict = windowDict[kCGWindowBounds] as? [String: Any] else {
                continue
            }

            // Parse bounds
            guard let x = boundsDict["X"] as? Double,
                  let y = boundsDict["Y"] as? Double,
                  let width = boundsDict["Width"] as? Double,
                  let height = boundsDict["Height"] as? Double else {
                continue
            }

            // Skip tiny windows (likely menu bar items, status icons, etc.)
            guard width >= 10 && height >= 10 else { continue }

            let layer = windowDict[kCGWindowLayer] as? Int32 ?? 0
            let alpha = windowDict[kCGWindowAlpha] as? Double ?? 1.0
            let isOnScreen = windowDict[kCGWindowIsOnscreen] as? Bool ?? true
            let title = windowDict[kCGWindowName] as? String ?? ""

            // Get bundle ID for the owning process
            let bundleId = bundleIdForPid(pid)

            // Skip system UI elements (menu bar, dock, notification center, etc.)
            if shouldSkipWindow(ownerName: ownerName, bundleId: bundleId, layer: layer) {
                continue
            }

            let info = WindowInfo(
                windowId: windowId,
                appName: ownerName,
                bundleId: bundleId,
                pid: pid,
                title: title,
                layer: layer,
                x: Int(x),
                y: Int(y),
                width: Int(width),
                height: Int(height),
                isOnScreen: isOnScreen,
                alpha: alpha
            )

            windows.append(info)
        }

        return WindowSnapshot(
            timestamp: Date(),
            windows: windows,
            displayWidth: displayWidth,
            displayHeight: displayHeight
        )
    }

    /// Capture just the layout summary (lightweight, for frequent polling).
    func captureLayoutSummary() -> WindowLayoutSummary? {
        guard let snapshot = captureSnapshot() else { return nil }
        return WindowLayoutSummary(from: snapshot)
    }

    // MARK: - Private Helpers

    /// Get bundle ID for a process ID.
    private func bundleIdForPid(_ pid: Int32) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.bundleIdentifier
    }

    /// Determine if a window should be skipped (system UI, overlays, etc.).
    private func shouldSkipWindow(ownerName: String, bundleId: String?, layer: Int32) -> Bool {
        // Skip non-normal layers (menu bar, dock, overlays)
        if layer != 0 { return true }

        // Skip known system UI apps
        let systemApps: Set<String> = [
            "Window Server",
            "Dock",
            "SystemUIServer",
            "Control Center",
            "Notification Center",
            "Spotlight",
            "com.apple.dock",
            "com.apple.systemuiserver",
            "com.apple.controlcenter",
            "com.apple.notificationcenterui",
            "com.apple.Spotlight",
        ]

        if systemApps.contains(ownerName) { return true }

        if let bundleId = bundleId {
            let systemBundles: Set<String> = [
                "com.apple.dock",
                "com.apple.systemuiserver",
                "com.apple.controlcenter",
                "com.apple.notificationcenterui",
                "com.apple.Spotlight",
                "com.apple.loginwindow",
            ]
            if systemBundles.contains(bundleId) { return true }
        }

        return false
    }
}
