import Foundation
import TaskMinerShared

/// Generates notification candidates from various sources:
/// - Today's recommendations (from stubs_content table)
/// - Activity insights (focus time, work patterns)
/// - Time-based prompts (end-of-day wrap-up)
struct NotificationCandidateGenerator {

    /// Generate notification candidates from all available sources.
    func generateCandidates(
        db: DatabaseManager,
        enabledCategories: Set<String>,
        preferChatPrompts: Bool
    ) async -> [NotificationCandidate] {
        var candidates: [NotificationCandidate] = []

        // Source 1: Today's recommendations
        let recommendationCandidates = await generateFromRecommendations(
            db: db,
            enabledCategories: enabledCategories,
            preferChatPrompts: preferChatPrompts
        )
        candidates.append(contentsOf: recommendationCandidates)

        // Source 2: Activity insights (future enhancement)
        // let insightCandidates = generateActivityInsights(db: db)
        // candidates.append(contentsOf: insightCandidates)

        return candidates
    }

    // MARK: - Recommendation-Based Candidates

    private func generateFromRecommendations(
        db: DatabaseManager,
        enabledCategories: Set<String>,
        preferChatPrompts: Bool
    ) async -> [NotificationCandidate] {
        // Load today's stubs content from the database
        let today = SharedFormatters.dayFormatter.string(from: Date())
        guard let stubsRecord = loadStubsContent(date: today, db: db) else {
            return []
        }

        // Parse recommendations JSON
        guard let data = stubsRecord.recommendationsJson.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }

        var candidates: [NotificationCandidate] = []

        for item in items {
            guard let categoryStr = item["category"] as? String,
                  let title = item["title"] as? String,
                  let description = item["description"] as? String,
                  let reason = item["reason"] as? String
            else { continue }

            // Filter by enabled categories
            guard enabledCategories.contains(categoryStr) else { continue }

            let category = NotificationCategory(rawValue: categoryStr) ?? .bestPractice
            let actionURL = item["action_url"] as? String

            // Determine notification type and payload
            let (type, payload) = determineTypeAndPayload(
                category: category,
                title: title,
                reason: reason,
                actionURL: actionURL,
                preferChatPrompts: preferChatPrompts
            )

            // Create candidate with initial scoring inputs
            let candidate = NotificationCandidate(
                type: type,
                category: category,
                title: truncateForNotification(title, maxLength: 50),
                body: truncateForNotification(description, maxLength: 120),
                payload: payload,
                contentRelevance: estimateContentRelevance(reason: reason),
                contextScore: 0.5,  // Will be refined by scorer
                urgency: estimateUrgency(category: category),
                recencyPenalty: 0.0,  // Will be calculated by scorer
                source: "recommendation",
                sourceRecommendationId: nil
            )

            candidates.append(candidate)
        }

        return candidates
    }

    // MARK: - Type & Payload Determination

    private func determineTypeAndPayload(
        category: NotificationCategory,
        title: String,
        reason: String,
        actionURL: String?,
        preferChatPrompts: Bool
    ) -> (NotificationType, NotificationPayload?) {
        // If user prefers chat prompts, generate a question
        if preferChatPrompts || actionURL == nil {
            let prompt = generateChatPrompt(
                category: category,
                title: title,
                reason: reason
            )
            return (.chatPrompt, NotificationPayload(chatPrompt: prompt))
        }

        // Otherwise use the URL
        return (.link, NotificationPayload(url: actionURL))
    }

    private func generateChatPrompt(
        category: NotificationCategory,
        title: String,
        reason: String
    ) -> String {
        switch category {
        case .article:
            return "Tell me more about \(title)"
        case .tool:
            return "How can I use \(title) in my workflow?"
        case .bestPractice:
            return "What's the best approach for \(title)?"
        case .workflow:
            return "How can I improve my workflow with \(title)?"
        case .learning:
            return "Help me understand \(title)"
        case .exploration:
            return "What interesting things can I learn about \(title)?"
        }
    }

    // MARK: - Content Analysis

    private func estimateContentRelevance(reason: String) -> Double {
        // Higher relevance for reasons that mention specific projects, technologies, or recent work
        let relevanceIndicators = [
            "you're working on": 0.2,
            "your recent": 0.2,
            "you've been": 0.15,
            "your project": 0.2,
            "based on": 0.1,
            "you mentioned": 0.15
        ]

        var score = 0.5  // Base relevance
        let lowerReason = reason.lowercased()

        for (indicator, bonus) in relevanceIndicators {
            if lowerReason.contains(indicator) {
                score += bonus
            }
        }

        return min(1.0, score)
    }

    private func estimateUrgency(category: NotificationCategory) -> Double {
        // Some categories are more time-sensitive than others
        switch category {
        case .workflow:
            return 0.8  // High urgency - actionable now
        case .bestPractice:
            return 0.7  // Medium-high urgency
        case .tool:
            return 0.6  // Medium urgency
        case .article:
            return 0.4  // Lower urgency - can read later
        case .learning:
            return 0.3  // Low urgency - evergreen content
        case .exploration:
            return 0.2  // Lowest urgency - casual discovery
        }
    }

    // MARK: - Helpers

    private func truncateForNotification(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let truncated = String(text.prefix(maxLength - 3))
        // Find last word boundary
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "..."
        }
        return truncated + "..."
    }

    private func loadStubsContent(date: String, db: DatabaseManager) -> StubsContentRecord? {
        // We need to query the database for stubs content
        // Since DatabaseManager doesn't have this method, we'll use a direct query
        // For now, return nil - this will be implemented via DatabaseReader
        return nil
    }
}

// MARK: - Database Record (Matches DatabaseReader)

struct StubsContentRecord {
    let id: Int64
    let date: String
    let greetingContext: String
    let daySummary: String?
    let questionsJson: String
    let recommendationsJson: String
    let generatedAt: Date
}
