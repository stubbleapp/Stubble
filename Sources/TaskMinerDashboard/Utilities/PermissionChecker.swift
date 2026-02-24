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

    /// Check Screen Recording permission by listing on-screen windows.
    /// IMPORTANT: CGPreflightScreenCaptureAccess() caches its result per-process
    /// and never reflects newly-granted TCC permissions.
    ///
    /// Instead we use CGWindowListCopyWindowInfo, which returns window names and
    /// owner details for other apps ONLY when Screen Recording is granted. Without
    /// permission, window names from other processes come back as nil/empty.
    /// We check whether any non-own-process window has a non-empty name.
    static func checkScreenRecording() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID != myPID else { continue }
            // Without Screen Recording, window names from other apps are nil/empty
            if let name = window[kCGWindowName as String] as? String, !name.isEmpty {
                return true
            }
        }
        return false
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
