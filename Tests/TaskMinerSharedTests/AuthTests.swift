import XCTest
@testable import TaskMinerShared

// MARK: - AuthManager Static Methods

final class AuthManagerTests: XCTestCase {

    // MARK: - extractAuthCode

    func testExtractAuthCodeFromValidCallback() {
        let url = URL(string: "com.stubble://auth-callback?code=abc123")!
        XCTAssertEqual(AuthManager.extractAuthCode(from: url), "abc123")
    }

    func testExtractAuthCodeFromCallbackWithMultipleParams() {
        let url = URL(string: "com.stubble://auth-callback?code=xyz789&state=foo")!
        XCTAssertEqual(AuthManager.extractAuthCode(from: url), "xyz789")
    }

    func testExtractAuthCodeReturnsNilForWrongScheme() {
        let url = URL(string: "https://auth-callback?code=abc123")!
        XCTAssertNil(AuthManager.extractAuthCode(from: url))
    }

    func testExtractAuthCodeReturnsNilForWrongHost() {
        let url = URL(string: "com.stubble://other-path?code=abc123")!
        XCTAssertNil(AuthManager.extractAuthCode(from: url))
    }

    func testExtractAuthCodeReturnsNilWhenNoCode() {
        let url = URL(string: "com.stubble://auth-callback?state=foo")!
        XCTAssertNil(AuthManager.extractAuthCode(from: url))
    }

    func testExtractAuthCodeReturnsNilForEmptyURL() {
        let url = URL(string: "com.stubble://auth-callback")!
        XCTAssertNil(AuthManager.extractAuthCode(from: url))
    }

    // MARK: - AuthState Equatable

    func testAuthStateEquatable() {
        XCTAssertEqual(AuthManager.AuthState.signedOut, AuthManager.AuthState.signedOut)
        XCTAssertEqual(AuthManager.AuthState.pro, AuthManager.AuthState.pro)
        XCTAssertEqual(AuthManager.AuthState.expired, AuthManager.AuthState.expired)
        XCTAssertEqual(AuthManager.AuthState.byok, AuthManager.AuthState.byok)
        XCTAssertEqual(AuthManager.AuthState.trial(daysRemaining: 15), AuthManager.AuthState.trial(daysRemaining: 15))
        XCTAssertNotEqual(AuthManager.AuthState.trial(daysRemaining: 15), AuthManager.AuthState.trial(daysRemaining: 10))
        XCTAssertNotEqual(AuthManager.AuthState.signedOut, AuthManager.AuthState.pro)
    }

    // MARK: - AuthError Descriptions

    func testAuthErrorDescriptions() {
        XCTAssertNotNil(AuthManager.AuthError.invalidURL.errorDescription)
        XCTAssertNotNil(AuthManager.AuthError.noAuthCode.errorDescription)
        XCTAssertNotNil(AuthManager.AuthError.networkError("test").errorDescription)
        XCTAssertNotNil(AuthManager.AuthError.tokenExchangeFailed("msg").errorDescription)
        XCTAssertNotNil(AuthManager.AuthError.sessionExpired.errorDescription)
    }

    func testSessionExpiredErrorContainsSignInHint() {
        let desc = AuthManager.AuthError.sessionExpired.errorDescription!
        XCTAssertTrue(desc.lowercased().contains("sign in"))
    }

    func testNetworkErrorIncludesMessage() {
        let desc = AuthManager.AuthError.networkError("connection refused").errorDescription!
        XCTAssertTrue(desc.contains("connection refused"))
    }

    func testTokenExchangeFailedIncludesMessage() {
        let desc = AuthManager.AuthError.tokenExchangeFailed("bad grant").errorDescription!
        XCTAssertTrue(desc.contains("bad grant"))
    }

    // MARK: - Notification Name

    func testAuthStateChangedNotificationName() {
        XCTAssertEqual(Notification.Name.authStateChanged.rawValue, "stubble.authStateChanged")
    }
}

// MARK: - StubbleAPIConfig

final class StubbleAPIConfigTests: XCTestCase {

    func testIsConfigured() {
        // Since we've replaced placeholders with real values, this should be true
        XCTAssertTrue(StubbleAPIConfig.isConfigured)
    }

    func testCallbackURL() {
        XCTAssertEqual(StubbleAPIConfig.callbackURL, "com.stubble://auth-callback")
    }

    func testCallbackScheme() {
        XCTAssertEqual(StubbleAPIConfig.callbackScheme, "com.stubble")
    }

    func testTrialDays() {
        XCTAssertEqual(StubbleAPIConfig.trialDays, 10)
    }

    func testProxyBaseURLIsHTTPS() {
        XCTAssertTrue(StubbleAPIConfig.proxyBaseURL.hasPrefix("https://"))
    }

    func testSupabaseURLIsHTTPS() {
        XCTAssertTrue(StubbleAPIConfig.supabaseURL.hasPrefix("https://"))
    }
}

// MARK: - GeminiError Descriptions

final class GeminiErrorTests: XCTestCase {

    func testSessionExpiredDescription() {
        let desc = GeminiError.sessionExpired.localizedDescription
        XCTAssertTrue(desc.lowercased().contains("session"))
        XCTAssertTrue(desc.lowercased().contains("expired") || desc.lowercased().contains("sign in"))
    }

    func testTrialExpiredDescription() {
        let desc = GeminiError.trialExpired.localizedDescription
        XCTAssertTrue(desc.lowercased().contains("trial"))
        XCTAssertTrue(desc.lowercased().contains("upgrade") || desc.lowercased().contains("ended"))
    }

    func testRateLimitedDescription() {
        let desc = GeminiError.rateLimited.localizedDescription
        XCTAssertTrue(desc.lowercased().contains("limit"))
    }

    func testInvalidURLDescription() {
        let desc = GeminiError.invalidURL.localizedDescription
        XCTAssertTrue(desc.lowercased().contains("url"))
    }

    func testParseErrorIncludesMessage() {
        let desc = GeminiError.parseError("bad json").localizedDescription
        XCTAssertTrue(desc.contains("bad json"))
    }

    func testApiErrorIncludesCode() {
        let desc = GeminiError.apiError(statusCode: 500, message: "server error").localizedDescription
        XCTAssertTrue(desc.contains("500"))
        XCTAssertTrue(desc.contains("server error"))
    }
}
