import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

/// Permission checking utilities for the Dashboard app.
/// Provides both status checks and helpers to open System Settings.
enum PermissionChecker {

    /// Check if Accessibility permission is granted.
    /// When `promptIfNeeded` is true, macOS shows the system trust dialog.
    static func checkAccessibility(promptIfNeeded: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Check Screen Recording permission without triggering a system prompt.
    /// Uses CGPreflightScreenCaptureAccess (macOS 10.15+) which queries TCC
    /// directly rather than attempting a capture (which itself triggers the dialog).
    static func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Open System Settings → Privacy & Security → Accessibility.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings → Privacy & Security → Screen Recording.
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
