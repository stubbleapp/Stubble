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
}
