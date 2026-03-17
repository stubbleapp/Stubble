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

    /// Whether the user completed Google OAuth sign-in during setup.
    public var isSignedInViaGoogle: Bool = false

    /// Permission flags — the view layer polls and updates these.
    public var accessibilityGranted: Bool = false
    public var screenRecordingGranted: Bool = false

    public let totalPages: Int = 3

    public init() {}

    // MARK: - Computed

    /// Whether the Continue button should be enabled for the current page.
    public var canContinue: Bool {
        switch currentPage {
        case 0:
            return true
        case 1:
            // Require Google sign-in to continue
            return isSignedInViaGoogle
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
        if currentPage == 0 { return "Get Started" }
        if isOnLastPage { return "Open Stubble" }
        return "Continue"
    }

    // MARK: - Navigation

    /// Set the current page directly (for restoring state).
    public func setPage(_ page: Int) {
        guard page >= 0 && page < totalPages else { return }
        currentPage = page
    }

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

    /// Handle the Continue button press. Returns true if the page advanced.
    @discardableResult
    public func handleContinue() -> Bool {
        guard canContinue else { return false }
        return advance()
    }
}
