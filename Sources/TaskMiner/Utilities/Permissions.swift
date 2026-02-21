import Foundation
import ApplicationServices
import CoreGraphics

enum Permissions {
    /// Check if Accessibility permission is granted.
    /// When promptIfNeeded is true, macOS shows the system dialog.
    static func checkAccessibility(promptIfNeeded: Bool = true) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Test Screen Recording permission by attempting a minimal capture.
    /// If permission is not granted, the capture returns nil or a blank image.
    static func checkScreenRecording() -> Bool {
        // Try to capture a 1x1 region — if screen recording is denied,
        // this returns nil on recent macOS versions
        let testImage = CGWindowListCreateImage(
            CGRect(x: 0, y: 0, width: 1, height: 1),
            .optionOnScreenOnly,
            kCGNullWindowID,
            []
        )
        return testImage != nil
    }

    static func printGuidance() {
        let msg = """

        ⚠️  TaskMiner requires macOS permissions to function:

        1. ACCESSIBILITY (required for reading window titles):
           System Settings → Privacy & Security → Accessibility
           → Add Terminal.app (or the TaskMiner binary)

        2. SCREEN RECORDING (required for screenshots):
           System Settings → Privacy & Security → Screen Recording
           → Add Terminal.app (or the TaskMiner binary)

        After granting permissions, restart TaskMiner.

        """
        fputs(msg, stderr)
    }
}
