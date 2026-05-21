import XCTest
@testable import TaskMinerShared

final class ChatIntentClassifierTests: XCTestCase {

    // MARK: - Activity Query Patterns

    func testClassifiesActivityQueries() {
        // "What did I" patterns
        XCTAssertEqual(ChatIntentClassifier.classify("What did I do today?"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("What did I work on yesterday?"), .activityQuery)

        // Time-related queries
        XCTAssertEqual(ChatIntentClassifier.classify("How much time on Stubble?"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("How long did I spend coding?"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("How many hours did I work?"), .activityQuery)

        // Summarization requests
        XCTAssertEqual(ChatIntentClassifier.classify("Summarize my day"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("Describe my day"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("How was my day?"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("Tell me about my day"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("Walk me through my day"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("Recap my morning"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("Review my activity"), .activityQuery)

        // Project/app/meeting queries
        XCTAssertEqual(ChatIntentClassifier.classify("What projects did I work on?"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("Which apps did I use?"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("What meetings did I have?"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("What tasks did I complete?"), .activityQuery)

        // List/show patterns
        XCTAssertEqual(ChatIntentClassifier.classify("List my activities"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("Show me my timeline"), .activityQuery)
    }

    // MARK: - Action Request Patterns

    func testClassifiesActionRequests() {
        // Help patterns
        XCTAssertEqual(ChatIntentClassifier.classify("Help me optimize the database"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Help with my code"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Can you help me debug this?"), .actionRequest)

        // How-to patterns
        XCTAssertEqual(ChatIntentClassifier.classify("How do I implement caching?"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("How can I improve performance?"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("How should I structure this?"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("How would I test this?"), .actionRequest)

        // Imperative verbs
        XCTAssertEqual(ChatIntentClassifier.classify("Fix the login bug"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Debug this crash"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Optimize the query"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Refactor this function"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Implement the feature"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Write a test for this"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Create a new component"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Build the UI"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Design the architecture"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Analyze the performance"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Solve this problem"), .actionRequest)

        // Advice patterns
        XCTAssertEqual(ChatIntentClassifier.classify("What's the best way to cache?"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Best practice for error handling"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Recommend a library for this"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Suggest an approach"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Give me advice on testing"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Tips for debugging"), .actionRequest)

        // Guide/walkthrough patterns
        XCTAssertEqual(ChatIntentClassifier.classify("Guide me through this"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Walk me through the process"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Show me how to do this"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Tell me how to fix it"), .actionRequest)

        // Explain (action, not knowledge)
        XCTAssertEqual(ChatIntentClassifier.classify("Explain TCC permissions"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Explain how this works"), .actionRequest)
    }

    // MARK: - General Knowledge Patterns

    func testClassifiesGeneralKnowledge() {
        // "What is/are" patterns
        XCTAssertEqual(ChatIntentClassifier.classify("What is a monad?"), .generalKnowledge)
        XCTAssertEqual(ChatIntentClassifier.classify("What are generics?"), .generalKnowledge)

        // "Who is" patterns
        XCTAssertEqual(ChatIntentClassifier.classify("Who is Alan Turing?"), .generalKnowledge)

        // "Why is/does/do" patterns
        XCTAssertEqual(ChatIntentClassifier.classify("Why is the sky blue?"), .generalKnowledge)
        XCTAssertEqual(ChatIntentClassifier.classify("Why does Swift use ARC?"), .generalKnowledge)
        XCTAssertEqual(ChatIntentClassifier.classify("Why do computers use binary?"), .generalKnowledge)
    }

    // MARK: - Default Behavior

    func testDefaultsToActionRequest() {
        // Ambiguous queries should default to actionRequest (being helpful > descriptive)
        XCTAssertEqual(ChatIntentClassifier.classify("Tell me about Swift"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("random question"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("something something code"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("just testing"), .actionRequest)
    }

    // MARK: - Edge Cases

    func testHandlesEmptyAndWhitespace() {
        XCTAssertEqual(ChatIntentClassifier.classify(""), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("   "), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("\n\t"), .actionRequest)
    }

    func testCaseInsensitive() {
        // Activity queries should work regardless of case
        XCTAssertEqual(ChatIntentClassifier.classify("WHAT DID I DO TODAY?"), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("What Did I Do Today?"), .activityQuery)

        // Action requests should work regardless of case
        XCTAssertEqual(ChatIntentClassifier.classify("HELP ME FIX THIS"), .actionRequest)
        XCTAssertEqual(ChatIntentClassifier.classify("Help Me Fix This"), .actionRequest)

        // General knowledge should work regardless of case
        XCTAssertEqual(ChatIntentClassifier.classify("WHAT IS A MONAD?"), .generalKnowledge)
        XCTAssertEqual(ChatIntentClassifier.classify("What Is A Monad?"), .generalKnowledge)
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(ChatIntentClassifier.classify("  What did I do today?  "), .activityQuery)
        XCTAssertEqual(ChatIntentClassifier.classify("\nHelp me fix this\n"), .actionRequest)
    }
}
