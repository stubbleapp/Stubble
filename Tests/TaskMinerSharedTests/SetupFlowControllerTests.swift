import XCTest
@testable import TaskMinerShared

final class SetupFlowControllerTests: XCTestCase {

    private func makeController() -> SetupFlowController {
        SetupFlowController()
    }

    // MARK: - Initial State

    func testInitialState() {
        let c = makeController()
        XCTAssertEqual(c.currentPage, 0)
        XCTAssertEqual(c.totalPages, 4)
        XCTAssertTrue(c.apiKey.isEmpty)
        XCTAssertFalse(c.isValidating)
        XCTAssertNil(c.apiKeyError)
        XCTAssertFalse(c.apiKeyValidated)
        XCTAssertFalse(c.accessibilityGranted)
        XCTAssertFalse(c.screenRecordingGranted)
    }

    // MARK: - Page Navigation

    func testAdvanceFromFirstPage() {
        let c = makeController()
        XCTAssertTrue(c.advance())
        XCTAssertEqual(c.currentPage, 1)
    }

    func testAdvanceToLastPage() {
        let c = makeController()
        for _ in 0..<3 { c.advance() }
        XCTAssertEqual(c.currentPage, 3)
    }

    func testAdvanceBeyondLastPage() {
        let c = makeController()
        for _ in 0..<3 { c.advance() }
        XCTAssertFalse(c.advance())
        XCTAssertEqual(c.currentPage, 3, "Should not go beyond last page")
    }

    func testGoBackFromSecondPage() {
        let c = makeController()
        c.advance()
        XCTAssertTrue(c.goBack())
        XCTAssertEqual(c.currentPage, 0)
    }

    func testGoBackFromFirstPage() {
        let c = makeController()
        XCTAssertFalse(c.goBack())
        XCTAssertEqual(c.currentPage, 0, "Should not go below page 0")
    }

    func testCanGoBackOnPage0() {
        let c = makeController()
        XCTAssertFalse(c.canGoBack)
    }

    func testCanGoBackOnPage1() {
        let c = makeController()
        c.advance()
        XCTAssertTrue(c.canGoBack)
    }

    // MARK: - isOnLastPage

    func testIsOnLastPage() {
        let c = makeController()
        XCTAssertFalse(c.isOnLastPage)
        for _ in 0..<3 { c.advance() }
        XCTAssertTrue(c.isOnLastPage)
    }

    // MARK: - Continue Button Enablement

    func testCanContinueOnWelcomePage() {
        let c = makeController()
        XCTAssertTrue(c.canContinue, "Welcome page should always allow continue")
    }

    func testCanContinueOnApiKeyPageWithEmptyKey() {
        let c = makeController()
        c.advance() // page 1
        XCTAssertFalse(c.canContinue, "Empty API key should block continue")
    }

    func testCanContinueOnApiKeyPageWithWhitespaceOnly() {
        let c = makeController()
        c.advance()
        c.apiKey = "   \n  "
        XCTAssertFalse(c.canContinue, "Whitespace-only key should block continue")
    }

    func testCanContinueOnApiKeyPageWithValidKey() {
        let c = makeController()
        c.advance()
        c.apiKey = "AIzaSyABC123"
        XCTAssertTrue(c.canContinue)
    }

    func testCanContinueOnApiKeyPageWhileValidating() {
        let c = makeController()
        c.advance()
        c.apiKey = "AIzaSyABC123"
        c.beginValidation()
        XCTAssertFalse(c.canContinue, "Should not continue while validating")
    }

    func testCanContinueOnPermissionsPageNeitherGranted() {
        let c = makeController()
        c.advance(); c.advance() // page 2
        XCTAssertFalse(c.canContinue, "No permissions = blocked")
    }

    func testCanContinueOnPermissionsPageOnlyAccessibility() {
        let c = makeController()
        c.advance(); c.advance()
        c.accessibilityGranted = true
        XCTAssertFalse(c.canContinue, "Only one permission = blocked")
    }

    func testCanContinueOnPermissionsPageOnlyScreenRecording() {
        let c = makeController()
        c.advance(); c.advance()
        c.screenRecordingGranted = true
        XCTAssertFalse(c.canContinue, "Only one permission = blocked")
    }

    func testCanContinueOnPermissionsPageBothGranted() {
        let c = makeController()
        c.advance(); c.advance()
        c.accessibilityGranted = true
        c.screenRecordingGranted = true
        XCTAssertTrue(c.canContinue)
    }

    func testCanContinueOnPreferencesPage() {
        let c = makeController()
        for _ in 0..<3 { c.advance() }
        XCTAssertTrue(c.canContinue, "Preferences page always allows continue")
    }

    // MARK: - allPermissionsGranted

    func testAllPermissionsGrantedFalseByDefault() {
        XCTAssertFalse(makeController().allPermissionsGranted)
    }

    func testAllPermissionsGrantedWhenBothSet() {
        let c = makeController()
        c.accessibilityGranted = true
        c.screenRecordingGranted = true
        XCTAssertTrue(c.allPermissionsGranted)
    }

    // MARK: - handleContinue

    func testHandleContinueOnWelcomePage() {
        let c = makeController()
        let action = c.handleContinue()
        XCTAssertEqual(action, .advance)
        XCTAssertEqual(c.currentPage, 1)
    }

    func testHandleContinueOnApiKeyPageTriggersValidation() {
        let c = makeController()
        c.advance()
        c.apiKey = "somekey"
        let action = c.handleContinue()
        XCTAssertEqual(action, .validate)
        XCTAssertEqual(c.currentPage, 1, "Should NOT advance — validation needed")
    }

    func testHandleContinueBlockedWhenCannotContinue() {
        let c = makeController()
        c.advance() // page 1, empty key
        let action = c.handleContinue()
        XCTAssertEqual(action, .blocked)
        XCTAssertEqual(c.currentPage, 1, "Should stay on same page")
    }

    func testHandleContinueOnPermissionsPageWithPermissions() {
        let c = makeController()
        c.advance(); c.advance() // page 2
        c.accessibilityGranted = true
        c.screenRecordingGranted = true
        let action = c.handleContinue()
        XCTAssertEqual(action, .advance)
        XCTAssertEqual(c.currentPage, 3)
    }

    // MARK: - API Key Validation Flow

    func testValidateApiKeyFormatEmpty() {
        let c = makeController()
        c.apiKey = ""
        XCTAssertNotNil(c.validateApiKeyFormat())
    }

    func testValidateApiKeyFormatWhitespace() {
        let c = makeController()
        c.apiKey = "   "
        XCTAssertNotNil(c.validateApiKeyFormat())
    }

    func testValidateApiKeyFormatValid() {
        let c = makeController()
        c.apiKey = "AIzaSyABC123"
        XCTAssertNil(c.validateApiKeyFormat())
    }

    func testBeginValidation() {
        let c = makeController()
        c.setApiKeyError("previous error")
        c.beginValidation()
        XCTAssertTrue(c.isValidating)
        XCTAssertNil(c.apiKeyError, "Error should be cleared on begin")
    }

    func testHandleValidationSuccess() {
        let c = makeController()
        c.advance() // page 1
        c.beginValidation()
        c.handleValidationSuccess()
        XCTAssertFalse(c.isValidating)
        XCTAssertTrue(c.apiKeyValidated)
        XCTAssertNil(c.apiKeyError)
        XCTAssertEqual(c.currentPage, 2, "Should advance to permissions page")
    }

    func testHandleValidationFailureAuthError() {
        let c = makeController()
        c.advance()
        c.beginValidation()
        let error = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTTP 401 Unauthorized"])
        c.handleValidationFailure(error)
        XCTAssertFalse(c.isValidating)
        XCTAssertFalse(c.apiKeyValidated)
        XCTAssertTrue(c.apiKeyError?.contains("invalid") ?? false)
    }

    func testHandleValidationFailureNetworkError() {
        let c = makeController()
        c.advance()
        c.beginValidation()
        let error = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "The network connection was lost"])
        c.handleValidationFailure(error)
        XCTAssertTrue(c.apiKeyError?.contains("Network") ?? false)
    }

    func testHandleValidationFailureGenericError() {
        let c = makeController()
        c.advance()
        c.beginValidation()
        let error = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Something unexpected happened"])
        c.handleValidationFailure(error)
        XCTAssertTrue(c.apiKeyError?.contains("Could not verify") ?? false)
    }

    // MARK: - Error Categorization

    func testCategorizeError403() {
        let error = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Gemini API error 403: forbidden"])
        let msg = SetupFlowController.categorizeError(error)
        XCTAssertTrue(msg.contains("invalid"))
    }

    func testCategorizeErrorApiKey() {
        let error = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "API key not valid"])
        let msg = SetupFlowController.categorizeError(error)
        XCTAssertTrue(msg.contains("invalid"))
    }

    func testCategorizeErrorTimeout() {
        let error = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Request timed out after 30 timeout seconds"])
        let msg = SetupFlowController.categorizeError(error)
        XCTAssertTrue(msg.contains("Network"))
    }

    func testCategorizeErrorGeneric() {
        let error = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unknown server error 500"])
        let msg = SetupFlowController.categorizeError(error)
        XCTAssertTrue(msg.contains("Could not verify"))
    }

    // MARK: - continueButtonLabel

    func testContinueButtonLabelOnWelcomePage() {
        let c = makeController()
        XCTAssertEqual(c.continueButtonLabel, "Get Started")
    }

    func testContinueButtonLabelOnOtherPages() {
        let c = makeController()
        c.advance()
        XCTAssertEqual(c.continueButtonLabel, "Continue")
    }

    func testContinueButtonLabelWhileValidating() {
        let c = makeController()
        c.advance()
        c.beginValidation()
        XCTAssertEqual(c.continueButtonLabel, "Verifying...")
    }

    // MARK: - Full Happy Path

    func testFullHappyPathWalkthrough() {
        let c = makeController()

        // Page 0: Welcome
        XCTAssertEqual(c.currentPage, 0)
        XCTAssertTrue(c.canContinue)
        XCTAssertEqual(c.handleContinue(), .advance)

        // Page 1: API Key
        XCTAssertEqual(c.currentPage, 1)
        c.apiKey = "AIzaSyABC123"
        XCTAssertEqual(c.handleContinue(), .validate)
        c.beginValidation()
        XCTAssertFalse(c.canContinue) // validating
        c.handleValidationSuccess()
        XCTAssertTrue(c.apiKeyValidated)

        // Page 2: Permissions
        XCTAssertEqual(c.currentPage, 2)
        XCTAssertFalse(c.canContinue)
        c.accessibilityGranted = true
        c.screenRecordingGranted = true
        XCTAssertTrue(c.canContinue)
        XCTAssertEqual(c.handleContinue(), .advance)

        // Page 3: Preferences (last page)
        XCTAssertEqual(c.currentPage, 3)
        XCTAssertTrue(c.isOnLastPage)
        XCTAssertTrue(c.canContinue)
    }

    // MARK: - Edge Cases

    func testBackFromPage1ResetsToPage0() {
        let c = makeController()
        c.advance()
        c.apiKey = "somekey"
        c.setApiKeyError("some error")
        c.goBack()
        XCTAssertEqual(c.currentPage, 0)
        // Error persists but key remains — user can go forward again
        XCTAssertEqual(c.apiKey, "somekey")
    }

    func testValidationStateSurvivesNavigation() {
        let c = makeController()
        c.advance()
        c.apiKey = "key"
        c.beginValidation()
        c.handleValidationSuccess()
        // Now on page 2
        c.goBack() // back to page 1
        XCTAssertTrue(c.apiKeyValidated, "Validation state should persist")
    }

    func testSetApiKeyError() {
        let c = makeController()
        c.setApiKeyError("Test error")
        XCTAssertEqual(c.apiKeyError, "Test error")
        c.setApiKeyError(nil)
        XCTAssertNil(c.apiKeyError)
    }

    func testCancelValidation() {
        let c = makeController()
        c.advance()
        c.beginValidation()
        XCTAssertTrue(c.isValidating)
        c.cancelValidation("Invalid key format.")
        XCTAssertFalse(c.isValidating)
        XCTAssertEqual(c.apiKeyError, "Invalid key format.")
    }
}
