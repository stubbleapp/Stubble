import XCTest
@testable import TaskMinerShared

final class DataSanitizerTests: XCTestCase {

    // MARK: - API Keys & Tokens

    func testRedactsPrefixedAPIKeys() {
        // Gemini / OpenAI style — "key=" matches the credential pattern first
        let geminiResult = DataSanitizer.sanitize("key=sk-abc123def456ghij7890klmnop")
        XCTAssertTrue(
            geminiResult.contains("[REDACTED"),
            "Expected key to be redacted, got: \(geminiResult)"
        )
        // GitHub PAT — "token:" matches credential pattern first
        let ghResult = DataSanitizer.sanitize("token: ghp_1234567890abcdefghij")
        XCTAssertTrue(
            ghResult.contains("[REDACTED"),
            "Expected GitHub PAT to be redacted, got: \(ghResult)"
        )
        XCTAssertFalse(ghResult.contains("ghp_"))
        // AWS access key (standalone, no "key=" prefix)
        XCTAssertEqual(
            DataSanitizer.sanitize("AKIAIOSFODNN7EXAMPLE1234"),
            "[REDACTED_KEY]"
        )
        // Slack bot token (standalone)
        XCTAssertEqual(
            DataSanitizer.sanitize("xoxb-1234567890-abcdefghij"),
            "[REDACTED_KEY]"
        )
        // HuggingFace token
        XCTAssertEqual(
            DataSanitizer.sanitize("hf_abcdefghijklmnop"),
            "[REDACTED_KEY]"
        )
        // Anthropic key
        XCTAssertEqual(
            DataSanitizer.sanitize("sk-ant-api03-abcdefghij1234567890"),
            "[REDACTED_KEY]"
        )
    }

    func testRedactsGenericLongTokens() {
        // 32+ char token after = sign — "secret=" matches credential pattern
        let token = String(repeating: "a", count: 40)
        let result = DataSanitizer.sanitize("secret=\(token)")
        XCTAssertTrue(
            result.contains("[REDACTED"),
            "Expected long token to be redacted, got: \(result)"
        )
        XCTAssertFalse(result.contains(token))

        // Token after a non-credential key (hits the generic token pattern)
        let result2 = DataSanitizer.sanitize("value=\(token)")
        XCTAssertTrue(
            result2.contains("[REDACTED_TOKEN]"),
            "Expected generic long token to be redacted, got: \(result2)"
        )
    }

    // MARK: - Credentials

    func testRedactsPasswordPatterns() {
        XCTAssertTrue(
            DataSanitizer.sanitize("password: hunter2").contains("[REDACTED_CREDENTIAL]")
        )
        XCTAssertTrue(
            DataSanitizer.sanitize("API_KEY=mySecretValue123").contains("[REDACTED_CREDENTIAL]")
        )
        XCTAssertTrue(
            DataSanitizer.sanitize("secret = shhh_dont_tell").contains("[REDACTED_CREDENTIAL]")
        )
    }

    // MARK: - Financial

    func testRedactsCreditCardNumbers() {
        // Visa format with spaces
        XCTAssertTrue(
            DataSanitizer.sanitize("Card: 4111 1111 1111 1111").contains("[REDACTED_CARD]")
        )
        // With dashes
        XCTAssertTrue(
            DataSanitizer.sanitize("4111-1111-1111-1111").contains("[REDACTED_CARD]")
        )
    }

    func testRedactsSSN() {
        XCTAssertTrue(
            DataSanitizer.sanitize("SSN: 123-45-6789").contains("[REDACTED_SSN]")
        )
        XCTAssertTrue(
            DataSanitizer.sanitize("SSN: 123 45 6789").contains("[REDACTED_SSN]")
        )
    }

    // MARK: - Email

    func testRedactsEmailAddresses() {
        XCTAssertEqual(
            DataSanitizer.sanitize("Contact: user@example.com for info"),
            "Contact: [REDACTED_EMAIL] for info"
        )
    }

    // MARK: - Bearer Tokens

    func testRedactsBearerTokens() {
        XCTAssertTrue(
            DataSanitizer.sanitize("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig").contains("[REDACTED_BEARER]")
        )
    }

    // MARK: - Connection Strings

    func testRedactsConnectionStrings() {
        XCTAssertTrue(
            DataSanitizer.sanitize("mongodb://user:pass@host:27017/db").contains("[REDACTED_CONNSTRING]")
        )
        XCTAssertTrue(
            DataSanitizer.sanitize("postgres://user:pass@localhost/mydb").contains("[REDACTED_CONNSTRING]")
        )
    }

    // MARK: - Benign Text Preservation

    func testPreservesNormalText() {
        let normal = "Working on the dashboard UI refactor in Xcode"
        XCTAssertEqual(DataSanitizer.sanitize(normal), normal)
    }

    func testPreservesShortAlphanumericStrings() {
        // Short strings should NOT be redacted as tokens
        let text = "commit abc123 merged into main"
        XCTAssertEqual(DataSanitizer.sanitize(text), text)
    }

    func testPreservesNormalURLs() {
        // URLs without credentials should be preserved
        let text = "Visiting https://github.com/user/repo"
        XCTAssertEqual(DataSanitizer.sanitize(text), text)
    }

    // MARK: - Batch Sanitization

    func testSanitizeAll() {
        let inputs = [
            "Normal text",
            "password: secret123",
            "More normal text"
        ]
        let results = DataSanitizer.sanitizeAll(inputs)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0], "Normal text")
        XCTAssertTrue(results[1].contains("[REDACTED_CREDENTIAL]"))
        XCTAssertEqual(results[2], "More normal text")
    }

    // MARK: - Multiple Patterns in One String

    func testRedactsMultiplePatternsInOneString() {
        let text = "password: hunter2 email: user@example.com"
        let sanitized = DataSanitizer.sanitize(text)
        XCTAssertTrue(sanitized.contains("[REDACTED_CREDENTIAL]"))
        XCTAssertTrue(sanitized.contains("[REDACTED_EMAIL]"))
        XCTAssertFalse(sanitized.contains("hunter2"))
        XCTAssertFalse(sanitized.contains("user@example.com"))
    }
}
