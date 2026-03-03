import XCTest
@testable import TaskMinerDashboard
@testable import TaskMinerShared

/// Tests for parsing recommendation JSON responses.
/// Uses the same parsing logic that RecommendationGenerator uses internally.
final class RecommendationParsingTests: XCTestCase {

    // MARK: - Valid Response Parsing

    func testParseValidRecommendationResponse() {
        let json = """
        {
          "greeting_context": "You've been deep in the permission system.",
          "suggested_questions": ["How to fix TCC?", "Optimize SQLite"],
          "recommendations": [
            {
              "category": "article",
              "title": "TCC Internals Guide",
              "description": "Deep dive into macOS permissions.",
              "reason": "You've been debugging TCC all week.",
              "action_url": "https://developer.apple.com/documentation/security",
              "icon": "lock.shield"
            }
          ]
        }
        """

        let content = parseStubsResponse(json)

        XCTAssertEqual(content.greetingContext, "You've been deep in the permission system.")
        XCTAssertEqual(content.suggestedQuestions, ["How to fix TCC?", "Optimize SQLite"])
        XCTAssertEqual(content.recommendations.count, 1)

        let rec = content.recommendations[0]
        XCTAssertEqual(rec.title, "TCC Internals Guide")
        XCTAssertEqual(rec.category, .article)
        XCTAssertEqual(rec.description, "Deep dive into macOS permissions.")
        XCTAssertEqual(rec.reason, "You've been debugging TCC all week.")
        XCTAssertEqual(rec.actionURL, "https://developer.apple.com/documentation/security")
        XCTAssertEqual(rec.iconName, "lock.shield")
    }

    func testParseMultipleRecommendations() {
        let json = """
        {
          "greeting_context": "Busy day with multiple projects.",
          "suggested_questions": [],
          "recommendations": [
            {
              "category": "tool",
              "title": "SwiftLint",
              "description": "Linter for Swift code.",
              "reason": "Your codebase is growing."
            },
            {
              "category": "best_practice",
              "title": "Dependency Injection",
              "description": "Improve testability.",
              "reason": "You're writing more tests."
            },
            {
              "category": "workflow",
              "title": "Git Hooks",
              "description": "Automate pre-commit checks.",
              "reason": "Prevent bad commits."
            }
          ]
        }
        """

        let content = parseStubsResponse(json)

        XCTAssertEqual(content.recommendations.count, 3)
        XCTAssertEqual(content.recommendations[0].category, .tool)
        XCTAssertEqual(content.recommendations[1].category, .bestPractice)
        XCTAssertEqual(content.recommendations[2].category, .workflow)
    }

    func testParseAllCategories() {
        let categories: [(String, Recommendation.Category)] = [
            ("article", .article),
            ("tool", .tool),
            ("best_practice", .bestPractice),
            ("workflow", .workflow),
            ("learning", .learning),
            ("exploration", .exploration)
        ]

        for (rawValue, expected) in categories {
            let json = """
            {
              "recommendations": [
                {
                  "category": "\(rawValue)",
                  "title": "Test",
                  "description": "Test desc",
                  "reason": "Test reason"
                }
              ]
            }
            """

            let content = parseStubsResponse(json)
            XCTAssertEqual(content.recommendations.count, 1)
            XCTAssertEqual(content.recommendations[0].category, expected, "Category '\(rawValue)' should parse to \(expected)")
        }
    }

    // MARK: - Missing/Invalid Fields

    func testParseMissingOptionalFields() {
        let json = """
        {
          "recommendations": [
            {
              "category": "article",
              "title": "No URL Article",
              "description": "This has no URL.",
              "reason": "Testing optional fields."
            }
          ]
        }
        """

        let content = parseStubsResponse(json)

        XCTAssertEqual(content.recommendations.count, 1)
        XCTAssertNil(content.recommendations[0].actionURL)
        XCTAssertEqual(content.greetingContext, "")
        XCTAssertTrue(content.suggestedQuestions.isEmpty)
    }

    func testParseInvalidCategoryFallsBack() {
        let json = """
        {
          "recommendations": [
            {
              "category": "invalid_category",
              "title": "Test",
              "description": "Test desc",
              "reason": "Test reason"
            }
          ]
        }
        """

        let content = parseStubsResponse(json)

        XCTAssertEqual(content.recommendations.count, 1)
        XCTAssertEqual(content.recommendations[0].category, .bestPractice, "Invalid category should fall back to bestPractice")
    }

    func testParseSkipsInvalidRecommendations() {
        let json = """
        {
          "recommendations": [
            {
              "category": "article",
              "title": "Valid",
              "description": "Valid desc",
              "reason": "Valid reason"
            },
            {
              "category": "article"
            },
            {
              "title": "Missing Category",
              "description": "Desc",
              "reason": "Reason"
            }
          ]
        }
        """

        let content = parseStubsResponse(json)

        // Only the first valid recommendation should be parsed
        XCTAssertEqual(content.recommendations.count, 1)
        XCTAssertEqual(content.recommendations[0].title, "Valid")
    }

    func testParseEmptyRecommendations() {
        let json = """
        {
          "greeting_context": "Hello",
          "recommendations": []
        }
        """

        let content = parseStubsResponse(json)

        XCTAssertEqual(content.greetingContext, "Hello")
        XCTAssertTrue(content.recommendations.isEmpty)
    }

    // MARK: - Day Summary Parsing

    func testParseDaySummaryResponse() {
        let json = """
        {
          "greeting_context": "A deep dive into the codebase.",
          "day_summary": "You spent most of the day working on the permission system. Notable deep work blocks in the morning. Good progress on the SQLite layer.",
          "suggested_questions": [],
          "recommendations": []
        }
        """

        let content = parseDaySummaryResponse(json)

        XCTAssertEqual(content.greetingContext, "A deep dive into the codebase.")
        XCTAssertNotNil(content.daySummary)
        XCTAssertTrue(content.daySummary!.contains("permission system"))
    }

    func testParseDaySummaryWithMarkdown() {
        let json = """
        {
          "greeting_context": "Summary for Monday.",
          "day_summary": "## Morning\\nDeep work on auth.\\n\\n## Afternoon\\nMeetings and reviews.",
          "suggested_questions": [],
          "recommendations": []
        }
        """

        let content = parseDaySummaryResponse(json)

        XCTAssertNotNil(content.daySummary)
        XCTAssertTrue(content.daySummary!.contains("Morning"))
        XCTAssertTrue(content.daySummary!.contains("Afternoon"))
    }

    // MARK: - Malformed JSON

    func testParseInvalidJSON() {
        let json = "This is not JSON at all"

        let content = parseStubsResponse(json)

        XCTAssertEqual(content.greetingContext, "")
        XCTAssertTrue(content.recommendations.isEmpty)
    }

    func testParsePartialJSON() {
        let json = """
        {
          "greeting_context": "Hello",
          "recommendations": "not an array"
        }
        """

        let content = parseStubsResponse(json)

        XCTAssertEqual(content.greetingContext, "")
        XCTAssertTrue(content.recommendations.isEmpty)
    }

    func testParseJSONWithMarkdownFence() {
        // AI sometimes wraps JSON in markdown code fences
        let json = """
        ```json
        {
          "greeting_context": "Wrapped in fence",
          "recommendations": [
            {
              "category": "article",
              "title": "Test",
              "description": "Test desc",
              "reason": "Test reason"
            }
          ]
        }
        ```
        """

        let content = parseStubsResponse(json)

        // JSONSanitizer should handle this
        XCTAssertEqual(content.greetingContext, "Wrapped in fence")
        XCTAssertEqual(content.recommendations.count, 1)
    }

    // MARK: - Helpers

    /// Simulate the parsing logic from RecommendationGenerator
    private func parseStubsResponse(_ response: String) -> StubsContent {
        guard let parsed = JSONSanitizer.parse(response) as? [String: Any],
              let items = parsed["recommendations"] as? [[String: Any]]
        else {
            return StubsContent(greetingContext: "", daySummary: nil, suggestedQuestions: [], recommendations: [])
        }

        let greetingContext = parsed["greeting_context"] as? String ?? ""
        let suggestedQuestions = parsed["suggested_questions"] as? [String] ?? []

        let recommendations = items.compactMap { dict -> Recommendation? in
            guard let categoryStr = dict["category"] as? String,
                  let title = dict["title"] as? String,
                  let description = dict["description"] as? String,
                  let reason = dict["reason"] as? String
            else { return nil }

            let category = Recommendation.Category(rawValue: categoryStr) ?? .bestPractice
            let actionURL = dict["action_url"] as? String
            let iconName = dict["icon"] as? String ?? category.defaultIcon

            return Recommendation(
                id: UUID(),
                category: category,
                title: title,
                description: description,
                reason: reason,
                actionLabel: actionURL != nil ? category.defaultActionLabel : "Noted",
                actionURL: actionURL,
                iconName: iconName
            )
        }

        return StubsContent(
            greetingContext: greetingContext,
            daySummary: nil,
            suggestedQuestions: suggestedQuestions,
            recommendations: recommendations
        )
    }

    private func parseDaySummaryResponse(_ response: String) -> StubsContent {
        guard let parsed = JSONSanitizer.parse(response) as? [String: Any] else {
            return StubsContent(greetingContext: "", daySummary: nil, suggestedQuestions: [], recommendations: [])
        }

        let greetingContext = parsed["greeting_context"] as? String ?? ""
        let daySummary = parsed["day_summary"] as? String
        let suggestedQuestions = parsed["suggested_questions"] as? [String] ?? []

        return StubsContent(
            greetingContext: greetingContext,
            daySummary: daySummary,
            suggestedQuestions: suggestedQuestions,
            recommendations: []
        )
    }
}
