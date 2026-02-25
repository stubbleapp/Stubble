import Foundation
import Observation

/// Testable state machine for the setup wizard flow.
/// Encapsulates page navigation, validation rules, and permission state —
/// keeping the SwiftUI view layer thin.
///
/// Marked `@Observable` so SwiftUI views can track property changes when
/// stored as `@State` (macOS 14+ / Swift 5.9+).
@Observable
public final class SetupFlowController {

    // MARK: - State

    public private(set) var currentPage: Int = 0
    public var apiKey: String = ""
    public private(set) var isValidating: Bool = false
    public private(set) var apiKeyError: String?
    public private(set) var apiKeyValidated: Bool = false

    /// Permission flags — the view layer polls and updates these.
    public var accessibilityGranted: Bool = false
    public var screenRecordingGranted: Bool = false

    public let totalPages: Int = 4

    public init() {}

    // MARK: - Computed

    /// Whether the Continue button should be enabled for the current page.
    public var canContinue: Bool {
        switch currentPage {
        case 0:
            return true
        case 1:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValidating
        case 2:
            return allPermissionsGranted
        default:
            return true
        }
    }

    /// Whether the Back button should be shown.
    public var canGoBack: Bool {
        currentPage > 0
    }

    /// True when both required macOS permissions are granted.
    public var allPermissionsGranted: Bool {
        accessibilityGranted && screenRecordingGranted
    }

    /// True when the wizard is on the last page.
    public var isOnLastPage: Bool {
        currentPage == totalPages - 1
    }

    /// The label for the Continue button on the current page.
    public var continueButtonLabel: String {
        if isValidating { return "Verifying..." }
        return currentPage == 0 ? "Get Started" : "Continue"
    }

    // MARK: - Navigation

    /// Advance to the next page. Returns true if the page changed.
    @discardableResult
    public func advance() -> Bool {
        guard currentPage < totalPages - 1 else { return false }
        currentPage += 1
        return true
    }

    /// Go back to the previous page. Returns true if the page changed.
    @discardableResult
    public func goBack() -> Bool {
        guard currentPage > 0 else { return false }
        currentPage -= 1
        return true
    }

    /// Handle the Continue button press. Returns `.advance` if the page should
    /// transition immediately, `.validate` if API key validation is needed,
    /// or `.blocked` if the button shouldn't have been enabled.
    public func handleContinue() -> ContinueAction {
        guard canContinue else { return .blocked }
        if currentPage == 1 {
            return .validate
        }
        advance()
        return .advance
    }

    // MARK: - API Key Validation

    /// Validate the API key format synchronously (no network call).
    /// Returns an error message or nil if the format is acceptable.
    public func validateApiKeyFormat() -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            return "Please enter your API key first."
        }
        return nil
    }

    /// Mark the beginning of an async API key validation.
    public func beginValidation() {
        isValidating = true
        apiKeyError = nil
    }

    /// Handle a successful API key verification from the network.
    public func handleValidationSuccess() {
        isValidating = false
        apiKeyValidated = true
        apiKeyError = nil
        advance()
    }

    /// Handle a failed API key verification. Categorizes the error
    /// into a user-friendly message.
    public func handleValidationFailure(_ error: Error) {
        isValidating = false
        apiKeyError = Self.categorizeError(error)
    }

    /// Cancel an in-progress validation with a specific error message.
    public func cancelValidation(_ error: String) {
        isValidating = false
        apiKeyError = error
    }

    /// Set the API key error directly (e.g. for format validation failures).
    public func setApiKeyError(_ message: String?) {
        apiKeyError = message
    }

    // MARK: - Error Categorization

    /// Convert an API/network error into a user-friendly message.
    public static func categorizeError(_ error: Error) -> String {
        let desc = error.localizedDescription.lowercased()
        if desc.contains("403") || desc.contains("401")
            || desc.contains("api key") || desc.contains("permission") {
            return "This API key is invalid. Please check it and try again."
        } else if desc.contains("timeout") || desc.contains("network") || desc.contains("internet") {
            return "Network error \u{2014} check your internet connection and try again."
        } else {
            return "Could not verify the key \u{2014} please try again."
        }
    }

    // MARK: - Types

    /// The result of `handleContinue()`.
    public enum ContinueAction: Equatable {
        /// The page advanced normally.
        case advance
        /// API key validation is needed before advancing.
        case validate
        /// The button shouldn't have been enabled (guard).
        case blocked
    }
}
