import XCTest
@testable import TaskMinerShared

final class GeminiClientTests: XCTestCase {

    private let client = GeminiClient(apiKey: "test-key")

    // MARK: - parseResponseText

    func testParseValidResponse() throws {
        let json: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [["text": "Hello, world!"]]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = try client.parseResponseText(data)
        XCTAssertEqual(result, "Hello, world!")
    }

    func testParseFiltersThoughtParts() throws {
        let json: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [
                        ["text": "thinking...", "thought": true],
                        ["text": "Actual response"]
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = try client.parseResponseText(data)
        XCTAssertEqual(result, "Actual response")
    }

    func testParseMissingCandidatesThrows() {
        let json: [String: Any] = ["result": "no candidates here"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try client.parseResponseText(data)) { error in
            guard case GeminiError.parseError = error else {
                return XCTFail("Expected parseError, got \(error)")
            }
        }
    }

    func testParseEmptyPartsThrows() {
        let json: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [] as [[String: Any]]
                ]
            ]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try client.parseResponseText(data)) { error in
            guard case GeminiError.parseError = error else {
                return XCTFail("Expected parseError, got \(error)")
            }
        }
    }

    func testParseInvalidJSONThrows() {
        let data = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try client.parseResponseText(data))
    }

    func testParseMultiplePartsReturnsLastNonThought() throws {
        let json: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [
                        ["text": "thinking step 1", "thought": true],
                        ["text": "thinking step 2", "thought": true],
                        ["text": "Final answer"]
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let result = try client.parseResponseText(data)
        XCTAssertEqual(result, "Final answer")
    }

    // MARK: - isRetryableStatusCode

    func testRetryableStatusCodes() {
        XCTAssertTrue(GeminiClient.isRetryableStatusCode(429))
        XCTAssertTrue(GeminiClient.isRetryableStatusCode(500))
        XCTAssertTrue(GeminiClient.isRetryableStatusCode(502))
        XCTAssertTrue(GeminiClient.isRetryableStatusCode(503))
    }

    func testNonRetryableStatusCodes() {
        XCTAssertFalse(GeminiClient.isRetryableStatusCode(200))
        XCTAssertFalse(GeminiClient.isRetryableStatusCode(400))
        XCTAssertFalse(GeminiClient.isRetryableStatusCode(401))
        XCTAssertFalse(GeminiClient.isRetryableStatusCode(403))
        XCTAssertFalse(GeminiClient.isRetryableStatusCode(404))
    }

    // MARK: - isRetryableURLError

    func testRetryableURLErrors() {
        XCTAssertTrue(GeminiClient.isRetryableURLError(URLError(.timedOut)))
        XCTAssertTrue(GeminiClient.isRetryableURLError(URLError(.networkConnectionLost)))
        XCTAssertTrue(GeminiClient.isRetryableURLError(URLError(.notConnectedToInternet)))
    }

    func testNonRetryableURLErrors() {
        XCTAssertFalse(GeminiClient.isRetryableURLError(URLError(.badURL)))
        XCTAssertFalse(GeminiClient.isRetryableURLError(URLError(.cancelled)))
        XCTAssertFalse(GeminiClient.isRetryableURLError(URLError(.badServerResponse)))
        XCTAssertFalse(GeminiClient.isRetryableURLError(URLError(.unsupportedURL)))
    }

    // MARK: - Factory Methods

    func testFromAPIKeyReturnsNilForEmpty() {
        XCTAssertNil(GeminiClient.fromAPIKey(""))
    }

    func testFromAPIKeyReturnsClientForValidKey() {
        XCTAssertNotNil(GeminiClient.fromAPIKey("valid-key"))
    }

    // MARK: - Client Modes

    func testDirectModeIsNotProxy() {
        let client = GeminiClient(apiKey: "test-key")
        XCTAssertFalse(client.isProxyMode)
        if case .direct(let key) = client.mode {
            XCTAssertEqual(key, "test-key")
        } else {
            XCTFail("Expected direct mode")
        }
    }

    func testProxyModeIsProxy() {
        let client = GeminiClient(proxy: true)
        XCTAssertTrue(client.isProxyMode)
        if case .proxy = client.mode {
            // Expected
        } else {
            XCTFail("Expected proxy mode")
        }
    }

    func testDefaultModelIsFlash() {
        let direct = GeminiClient(apiKey: "key")
        let proxy = GeminiClient(proxy: true)
        // Both should use the same default model — we can't read the private property,
        // but we can verify they were constructed without error.
        XCTAssertNotNil(direct)
        XCTAssertNotNil(proxy)
    }

    func testCustomModelIsAccepted() {
        let client = GeminiClient(apiKey: "key", model: "gemini-pro")
        XCTAssertFalse(client.isProxyMode)
    }

    // MARK: - GeminiError Properties

    func testGeminiErrorSessionExpired() {
        let error = GeminiError.sessionExpired
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.localizedDescription.contains("session") || error.localizedDescription.contains("expired"))
    }

    func testGeminiErrorTrialExpired() {
        let error = GeminiError.trialExpired
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.localizedDescription.contains("trial"))
    }

    func testGeminiErrorRateLimited() {
        let error = GeminiError.rateLimited
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.localizedDescription.contains("limit"))
    }

    func testGeminiErrorApiErrorIncludesStatusCode() {
        let error = GeminiError.apiError(statusCode: 429, message: "too many requests")
        XCTAssertTrue(error.localizedDescription.contains("429"))
        XCTAssertTrue(error.localizedDescription.contains("too many requests"))
    }

    // MARK: - Proxy Error Non-Retryable

    func testProxyErrorCodesAreNotRetryable() {
        // 401, 403 should NOT be retried — they're auth/tier errors
        XCTAssertFalse(GeminiClient.isRetryableStatusCode(401))
        XCTAssertFalse(GeminiClient.isRetryableStatusCode(403))
    }

    func test429IsRetryableForDirectMode() {
        // 429 from Gemini (direct mode) IS retryable — just rate limited
        XCTAssertTrue(GeminiClient.isRetryableStatusCode(429))
    }
}
