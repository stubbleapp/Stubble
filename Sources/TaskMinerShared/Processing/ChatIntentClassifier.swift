import Foundation

/// Classification of user chat query intent to determine optimal response strategy.
public enum ChatIntent: Sendable {
    /// User is asking about their past activity: "What did I do?", "How much time on X?"
    /// Response should cite specific times, durations, and activity data.
    case activityQuery

    /// User wants help accomplishing something: "Help me with X", "Optimize Y", "Fix Z"
    /// Response should provide actionable, expert-level advice.
    case actionRequest

    /// General knowledge question unrelated to user's tracked work.
    /// Response should be direct and informative with minimal activity context.
    case generalKnowledge
}

public enum ChatIntentClassifier {

    /// Classify user query intent using heuristic pattern matching.
    /// Defaults to `.actionRequest` for ambiguous queries since helpful > descriptive.
    public static func classify(_ query: String) -> ChatIntent {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Activity query patterns - user asking about their past work
        let activityPatterns = [
            "what did i",
            "what have i",
            "how much time",
            "how long did i",
            "when did i",
            "summarize my",
            "describe my day",
            "describe my",
            "my day",
            "how was my day",
            "tell me about my day",
            "what was i",
            "show me my",
            "list my",
            "what projects",
            "which apps",
            "what meetings",
            "recap my",
            "review my",
            "how many hours",
            "time spent on",
            "time on",
            "what tasks",
            "my activity",
            "walk me through my day",
            "overview of my day"
        ]

        for pattern in activityPatterns {
            if lower.contains(pattern) {
                return .activityQuery
            }
        }

        // Action request patterns - user wants help doing something
        let actionPatterns = [
            "help me",
            "help with",
            "how do i",
            "how can i",
            "how should i",
            "how would i",
            "explain",
            "optimize",
            "improve",
            "fix",
            "debug",
            "refactor",
            "implement",
            "write",
            "create",
            "build",
            "design",
            "analyze",
            "figure out",
            "solve",
            "what's the best way",
            "best practice",
            "recommend",
            "suggest",
            "advice on",
            "tips for",
            "guide me",
            "walk me through",
            "show me how",
            "tell me how",
            "can you help"
        ]

        for pattern in actionPatterns {
            if lower.contains(pattern) {
                return .actionRequest
            }
        }

        // Imperative verb starters - likely action requests
        let imperativeStarters = [
            "help", "explain", "fix", "debug", "optimize", "improve",
            "refactor", "implement", "write", "create", "build", "design",
            "analyze", "solve", "suggest", "recommend"
        ]

        let firstWord = String(lower.prefix(while: { $0.isLetter }))
        if imperativeStarters.contains(firstWord) {
            return .actionRequest
        }

        // Question about something general (not activity, not action)
        // Check if it starts with common question words but doesn't match activity patterns
        let questionStarters = ["what is", "what are", "who is", "why is", "why does", "why do"]
        for starter in questionStarters {
            if lower.hasPrefix(starter) {
                return .generalKnowledge
            }
        }

        // Default to action request - being helpful is better than being descriptive
        return .actionRequest
    }
}
