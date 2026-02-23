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

    /// Check Screen Recording permission without triggering a system prompt.
    /// Uses CGPreflightScreenCaptureAccess (macOS 10.15+) which queries TCC
    /// directly rather than attempting a capture (which itself triggers the dialog).
    static func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func printGuidance() {
        let msg = """

        ⚠️  Stubble requires macOS permissions to function:

        1. ACCESSIBILITY (required for reading window titles):
           System Settings → Privacy & Security → Accessibility
           → Add Terminal.app (or the Stubble binary)

        2. SCREEN RECORDING (required for screenshots):
           System Settings → Privacy & Security → Screen Recording
           → Add Terminal.app (or the Stubble binary)

        After granting permissions, restart Stubble.

        """
        fputs(msg, stderr)
    }
}
