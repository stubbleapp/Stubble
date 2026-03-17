import Foundation
import AppKit
import AuthenticationServices

/// Shared authentication helpers used by both SetupWizardView and SettingsView.
enum AuthHelpers {

    /// Convert raw OAuth/network errors into user-friendly messages.
    static func friendlyAuthError(_ error: Error) -> String {
        let desc = error.localizedDescription.lowercased()
        if desc.contains("network") || desc.contains("offline") || desc.contains("not connected") {
            return "No internet connection. Please check your network and try again."
        } else if desc.contains("timeout") || desc.contains("timed out") {
            return "The request timed out. Please try again."
        } else if desc.contains("unsupported_grant_type") || desc.contains("invalid_grant") {
            return "Authentication configuration error. Please try again."
        } else if desc.contains("server") || desc.contains("500") || desc.contains("503") {
            return "The authentication server is temporarily unavailable. Please try again later."
        } else {
            return "Sign-in failed. Please try again."
        }
    }
}

/// Shared ASWebAuthenticationSession presentation context.
/// Returns the key window (or any window) as the anchor for the auth sheet.
@MainActor
final class AuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
    }
}
