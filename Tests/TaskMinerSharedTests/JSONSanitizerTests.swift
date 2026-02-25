import XCTest
@testable import TaskMinerShared

final class JSONSanitizerTests: XCTestCase {

    // MARK: - Code Fence Stripping

    func testStripMarkdownCodeFences() {
        let input = """
        ```json
        {"key": "value"}
        ```
        """
        let result = JSONSanitizer.sanitize(input)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!))
    }

    func testStripPlainCodeFences() {
        let input = """
        ```
        {"key": "value"}
        ```
        """
        let result = JSONSanitizer.sanitize(input)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!))
    }

    func testStripUppercaseJSONFence() {
        let input = """
        ```JSON
        [1, 2, 3]
        ```
        """
        let result = JSONSanitizer.sanitize(input)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!))
    }

    // MARK: - Leading Text Extraction

    func testExtractJSONAfterLeadingText() {
        let input = "Here is the result: {\"key\": \"value\"}"
        let result = JSONSanitizer.sanitize(input)
        XCTAssertTrue(result.hasPrefix("{"))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!))
    }

    func testExtractArrayAfterLeadingText() {
        let input = "The tasks are: [\"a\", \"b\", \"c\"]"
        let result = JSONSanitizer.sanitize(input)
        XCTAssertTrue(result.hasPrefix("["))
    }

    // MARK: - Trailing Commas

    func testRemoveTrailingCommaInArray() {
        let input = "[1, 2, 3,]"
        let result = JSONSanitizer.sanitize(input)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!))
    }

    func testRemoveTrailingCommaInObject() {
        let input = "{\"a\": 1, \"b\": 2,}"
        let result = JSONSanitizer.sanitize(input)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!))
    }

    func testTrailingCommaWithWhitespace() {
        let input = """
        {
          "a": 1,
          "b": 2,
        }
        """
        let result = JSONSanitizer.sanitize(input)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!))
    }

    func testDoesNotRemoveCommaInsideString() {
        let input = "{\"greeting\": \"hello, world\"}"
        let result = JSONSanitizer.sanitize(input)
        let parsed = try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!) as? [String: String]
        XCTAssertEqual(parsed?["greeting"], "hello, world")
    }

    // MARK: - Comment Removal

    func testRemoveSingleLineComments() {
        let input = """
        {
          "a": 1, // this is a comment
          "b": 2
        }
        """
        let result = JSONSanitizer.sanitize(input)
        let parsed = try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["a"] as? Int, 1)
        XCTAssertEqual(parsed?["b"] as? Int, 2)
    }

    func testRemoveMultiLineComments() {
        let input = """
        {
          /* comment */
          "a": 1
        }
        """
        let result = JSONSanitizer.sanitize(input)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!))
    }

    func testDoesNotRemoveSlashesInsideStrings() {
        let input = "{\"url\": \"https://example.com\"}"
        let result = JSONSanitizer.sanitize(input)
        let parsed = try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!) as? [String: String]
        XCTAssertEqual(parsed?["url"], "https://example.com")
    }

    // MARK: - Control Character Escaping

    func testEscapesNewlinesInStrings() {
        // Raw newline inside a JSON string value
        let input = "{\"text\": \"line1\nline2\"}"
        let result = JSONSanitizer.sanitize(input)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!))
    }

    func testEscapesTabsInStrings() {
        let input = "{\"text\": \"col1\tcol2\"}"
        let result = JSONSanitizer.sanitize(input)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: result.data(using: .utf8)!))
    }

    // MARK: - Truncation Repair

    func testRepairTruncatedObject() {
        let input = "{\"a\": 1, \"b\": \"hello"
        let result = JSONSanitizer.sanitize(input)
        XCTAssertTrue(result.hasSuffix("}"), "Should close the truncated object")
    }

    func testRepairTruncatedArray() {
        let input = "[1, 2, 3"
        let result = JSONSanitizer.sanitize(input)
        XCTAssertTrue(result.hasSuffix("]"), "Should close the truncated array")
    }

    func testRepairNestedTruncation() {
        let input = "{\"tasks\": [{\"title\": \"test\""
        let result = JSONSanitizer.sanitize(input)
        // Should close the string, object, array, and outer object
        XCTAssertTrue(result.contains("}"))
        XCTAssertTrue(result.contains("]"))
    }

    // MARK: - parse() Integration

    func testParseValidJSON() {
        let input = "{\"tasks\": [], \"day_summary\": \"A productive day.\"}"
        let parsed = JSONSanitizer.parse(input)
        XCTAssertNotNil(parsed)

        let dict = parsed as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["day_summary"] as? String, "A productive day.")
    }

    func testParseMarkdownWrappedJSON() {
        let input = """
        ```json
        {"tasks": [{"title": "Coding"}]}
        ```
        """
        let parsed = JSONSanitizer.parse(input)
        XCTAssertNotNil(parsed)
    }

    func testParseReturnsNilForGarbage() {
        XCTAssertNil(JSONSanitizer.parse("this is not json at all"))
        XCTAssertNil(JSONSanitizer.parse(""))
    }

    func testParseArrayOfStrings() {
        let input = "[\"fact one\", \"fact two\"]"
        let parsed = JSONSanitizer.parse(input)
        let arr = parsed as? [String]
        XCTAssertEqual(arr, ["fact one", "fact two"])
    }

    // MARK: - Real-world LLM Responses

    func testRealWorldGeminiResponse() {
        let input = """
        ```json
        {
          "day_summary": "Spent the morning debugging Swift UI layout issues.",
          "tasks": [
            {
              "title": "Debugging SwiftUI layout",
              "description": "Working through VStack alignment issues in the settings view.",
              "start_time": "09:00:00",
              "end_time": "11:30:00",
              "active_seconds": 7200,
              "app_names": ["Xcode", "Safari"],
              "confidence": 0.9,
              "relevant_links": ["https://developer.apple.com/swiftui"],
            },
          ],
        }
        ```
        """
        let parsed = JSONSanitizer.parse(input)
        XCTAssertNotNil(parsed, "Should handle real-world Gemini response with trailing commas and code fences")

        let dict = parsed as? [String: Any]
        let tasks = dict?["tasks"] as? [[String: Any]]
        XCTAssertEqual(tasks?.count, 1)
        XCTAssertEqual(tasks?.first?["title"] as? String, "Debugging SwiftUI layout")
    }
}
