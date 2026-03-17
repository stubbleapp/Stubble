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
        XCTAssertEqual(c.totalPages, 3)
        XCTAssertFalse(c.accessibilityGranted)
        XCTAssertFalse(c.screenRecordingGranted)
        XCTAssertFalse(c.isSignedInViaGoogle)
    }

    // MARK: - Page Navigation

    func testAdvanceFromFirstPage() {
        let c = makeController()
        XCTAssertTrue(c.advance())
        XCTAssertEqual(c.currentPage, 1)
    }

    func testAdvanceToLastPage() {
        let c = makeController()
        for _ in 0..<2 { c.advance() }
        XCTAssertEqual(c.currentPage, 2)
    }

    func testAdvanceBeyondLastPage() {
        let c = makeController()
        for _ in 0..<2 { c.advance() }
        XCTAssertFalse(c.advance())
        XCTAssertEqual(c.currentPage, 2, "Should not go beyond last page")
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

    func testSetPage() {
        let c = makeController()
        c.setPage(2)
        XCTAssertEqual(c.currentPage, 2)
        c.setPage(0)
        XCTAssertEqual(c.currentPage, 0)
    }

    func testSetPageOutOfBounds() {
        let c = makeController()
        c.setPage(-1)
        XCTAssertEqual(c.currentPage, 0, "Should not go below 0")
        c.setPage(10)
        XCTAssertEqual(c.currentPage, 0, "Should not exceed totalPages")
    }

    // MARK: - isOnLastPage

    func testIsOnLastPage() {
        let c = makeController()
        XCTAssertFalse(c.isOnLastPage)
        for _ in 0..<2 { c.advance() }
        XCTAssertTrue(c.isOnLastPage)
    }

    // MARK: - Continue Button Enablement

    func testCanContinueOnWelcomePage() {
        let c = makeController()
        XCTAssertTrue(c.canContinue, "Welcome page should always allow continue")
    }

    func testCanContinueOnSignInPageWithoutSignIn() {
        let c = makeController()
        c.advance() // page 1
        XCTAssertFalse(c.canContinue, "Should require Google sign-in")
    }

    func testCanContinueOnSignInPageWithGoogleSignIn() {
        let c = makeController()
        c.advance() // page 1
        c.isSignedInViaGoogle = true
        XCTAssertTrue(c.canContinue)
    }

    func testCanContinueOnPermissionsPageNeitherGranted() {
        let c = makeController()
        c.advance()
        c.isSignedInViaGoogle = true
        c.advance() // page 2
        c.isSignedInViaGoogle = false // Reset for this test
        XCTAssertFalse(c.canContinue, "No permissions = blocked")
    }

    func testCanContinueOnPermissionsPageOnlyAccessibility() {
        let c = makeController()
        c.setPage(2)
        c.accessibilityGranted = true
        XCTAssertFalse(c.canContinue, "Only one permission = blocked")
    }

    func testCanContinueOnPermissionsPageOnlyScreenRecording() {
        let c = makeController()
        c.setPage(2)
        c.screenRecordingGranted = true
        XCTAssertFalse(c.canContinue, "Only one permission = blocked")
    }

    func testCanContinueOnPermissionsPageBothGranted() {
        let c = makeController()
        c.setPage(2)
        c.accessibilityGranted = true
        c.screenRecordingGranted = true
        XCTAssertTrue(c.canContinue)
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
        XCTAssertTrue(c.handleContinue())
        XCTAssertEqual(c.currentPage, 1)
    }

    func testHandleContinueBlockedWhenCannotContinue() {
        let c = makeController()
        c.advance() // page 1, not signed in
        XCTAssertFalse(c.handleContinue())
        XCTAssertEqual(c.currentPage, 1, "Should stay on same page")
    }

    func testHandleContinueOnSignInPageWithGoogleSignIn() {
        let c = makeController()
        c.advance() // page 1
        c.isSignedInViaGoogle = true
        XCTAssertTrue(c.handleContinue())
        XCTAssertEqual(c.currentPage, 2)
    }

    func testHandleContinueOnPermissionsPageWithPermissions() {
        let c = makeController()
        c.setPage(2)
        c.accessibilityGranted = true
        c.screenRecordingGranted = true
        // On last page, handleContinue returns false (no more pages)
        XCTAssertFalse(c.handleContinue())
        XCTAssertEqual(c.currentPage, 2, "Page doesn't change since already on last")
    }

    // MARK: - continueButtonLabel

    func testContinueButtonLabelOnWelcomePage() {
        let c = makeController()
        XCTAssertEqual(c.continueButtonLabel, "Get Started")
    }

    func testContinueButtonLabelOnMiddlePage() {
        let c = makeController()
        c.advance()
        XCTAssertEqual(c.continueButtonLabel, "Continue")
    }

    func testContinueButtonLabelOnLastPage() {
        let c = makeController()
        c.setPage(2)
        XCTAssertEqual(c.continueButtonLabel, "Open Stubble")
    }

    // MARK: - Full Happy Path

    func testFullHappyPathWithGoogleSignIn() {
        let c = makeController()

        // Page 0: Welcome
        XCTAssertEqual(c.currentPage, 0)
        XCTAssertTrue(c.canContinue)
        XCTAssertTrue(c.handleContinue())

        // Page 1: Sign-In
        XCTAssertEqual(c.currentPage, 1)
        XCTAssertFalse(c.canContinue)
        c.isSignedInViaGoogle = true
        XCTAssertTrue(c.canContinue)
        XCTAssertTrue(c.handleContinue())

        // Page 2: Permissions (last page)
        XCTAssertEqual(c.currentPage, 2)
        XCTAssertTrue(c.isOnLastPage)
        XCTAssertFalse(c.canContinue)
        c.accessibilityGranted = true
        c.screenRecordingGranted = true
        XCTAssertTrue(c.canContinue)
    }

    // MARK: - Edge Cases

    func testBackFromPage1ResetsToPage0() {
        let c = makeController()
        c.advance()
        c.isSignedInViaGoogle = true
        c.goBack()
        XCTAssertEqual(c.currentPage, 0)
        // Sign-in state persists
        XCTAssertTrue(c.isSignedInViaGoogle)
    }

    func testGoogleSignInStateDoesNotAffectOtherPages() {
        let c = makeController()
        c.isSignedInViaGoogle = true
        // Should not affect page 0
        XCTAssertTrue(c.canContinue, "Page 0 should always allow continue")
        _ = c.handleContinue() // → page 1
        _ = c.handleContinue() // → page 2 (Google signed in, so advance)
        XCTAssertFalse(c.canContinue, "Permissions page still requires permissions")
    }
}
