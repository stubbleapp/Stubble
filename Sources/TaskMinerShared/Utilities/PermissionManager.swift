import Foundation
import ApplicationServices
import CoreGraphics
import AppKit
import ScreenCaptureKit

/// Single source of truth for macOS TCC permission checks.
///
/// macOS grants Screen Recording and Accessibility permissions per **code signature**.
/// After a rebuild that changes the binary, the user must **remove** the app from the
/// permission list and **re-add** it in System Settings for macOS to pick up the new
/// code signature. Toggling off/on is NOT enough.
///
/// Used by both the Dashboard and the Daemon (via TaskMinerShared).
public enum PermissionManager {

    // MARK: - Combined Status

    public struct Status: Equatable, Sendable {
        public let accessibility: Bool
        public let screenRecording: Bool

        public var allGranted: Bool { accessibility && screenRecording }

        public var missingPermissions: [String] {
            var missing: [String] = []
            if !accessibility { missing.append("Accessibility") }
            if !screenRecording { missing.append("Screen Recording") }
            return missing
        }
    }

    /// Snapshot of both permission states. Screen Recording check is async because
    /// the only reliable API (ScreenCaptureKit) is async.
    public static func currentStatus() async -> Status {
        Status(
            accessibility: checkAccessibility(promptIfNeeded: false),
            screenRecording: await checkScreenRecording()
        )
    }

    // MARK: - Accessibility

    /// Check Accessibility (AX) permission.
    ///
    /// When `promptIfNeeded` is true, macOS shows the system trust dialog — but
    /// only for a brand-new executable. After a rebuild with a new ad-hoc
    /// signature, the dialog silently does nothing. Always direct the user to
    /// System Settings as a fallback.
    ///
    /// NOTE: `AXIsProcessTrustedWithOptions` caches per-process, but is generally
    /// more reliable than CGPreflight. After re-signing, the user must remove and
    /// re-add the app in System Settings > Accessibility.
    public static func checkAccessibility(promptIfNeeded: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): promptIfNeeded] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Screen Recording

    /// Check Screen Recording permission using ScreenCaptureKit.
    ///
    /// `SCShareableContent` is the only reliable, non-caching check on macOS 14+.
    /// It throws immediately when Screen Recording is not granted.
    ///
    /// **Do NOT use any of these — they are all broken:**
    /// - `CGPreflightScreenCaptureAccess()` — caches per-process, never reflects
    ///   newly-granted permissions.
    /// - `CGWindowListCreateImage` non-nil check — returns wallpaper (valid image)
    ///   even without permission.
    /// - `CGWindowListCopyWindowInfo` + window name check — system processes
    ///   (Dock, WindowServer, Control Center, Finder, etc.) expose window names
    ///   even without permission, causing false positives.
    public static func checkScreenRecording() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Request / Prompt

    /// Trigger the system prompt for Screen Recording access.
    /// Only shows a dialog for brand-new executables; after a rebuild it silently
    /// does nothing. Always follow up by opening System Settings.
    public static func requestScreenRecordingAccess() {
        CGRequestScreenCaptureAccess()
    }

    /// Trigger the system prompt for Accessibility access.
    /// Same caveat as Screen Recording re: rebuilt binaries.
    public static func requestAccessibilityAccess() {
        _ = checkAccessibility(promptIfNeeded: true)
    }

    // MARK: - Open System Settings

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
