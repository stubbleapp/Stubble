import Foundation
import TaskMinerShared

/// Multi-signal scoring for notification candidates.
/// Considers content relevance, context match, urgency, and recency to produce a final score.
struct NotificationRelevanceScorer {

    /// Score all candidates and return them with refined scores.
    func scoreAll(
        candidates: [NotificationCandidate],
        currentProject: String?,
        activeApp: String?,
        db: DatabaseManager,
        learningEnabled: Bool
    ) -> [NotificationCandidate] {
        return candidates.map { candidate in
            scoreCandidate(
                candidate,
                currentProject: currentProject,
                activeApp: activeApp,
                db: db,
                learningEnabled: learningEnabled
            )
        }
    }

    /// Score a single candidate with full context.
    private func scoreCandidate(
        _ candidate: NotificationCandidate,
        currentProject: String?,
        activeApp: String?,
        db: DatabaseManager,
        learningEnabled: Bool
    ) -> NotificationCandidate {
        // Refine context score based on current work
        let contextScore = calculateContextScore(
            candidate: candidate,
            currentProject: currentProject,
            activeApp: activeApp
        )

        // Calculate recency penalty
        let recencyPenalty = calculateRecencyPenalty(
            candidate: candidate,
            db: db
        )

        // Apply category confidence multiplier if learning is enabled
        let confidenceMultiplier: Double
        if learningEnabled {
            let stats = db.notificationCategoryStats(for: candidate.category)
            confidenceMultiplier = stats.confidence
        } else {
            confidenceMultiplier = 1.0
        }

        // Create updated candidate with refined scores
        return NotificationCandidate(
            id: candidate.id,
            type: candidate.type,
            category: candidate.category,
            title: candidate.title,
            body: candidate.body,
            payload: candidate.payload,
            contentRelevance: candidate.contentRelevance * confidenceMultiplier,
            contextScore: contextScore,
            urgency: candidate.urgency,
            recencyPenalty: recencyPenalty,
            source: candidate.source,
            sourceRecommendationId: candidate.sourceRecommendationId
        )
    }

    // MARK: - Context Score

    private func calculateContextScore(
        candidate: NotificationCandidate,
        currentProject: String?,
        activeApp: String?
    ) -> Double {
        var score = candidate.contextScore

        // Boost if the notification title/body mentions the current project
        if let project = currentProject?.lowercased(), !project.isEmpty {
            if candidate.title.lowercased().contains(project) ||
               candidate.body.lowercased().contains(project) {
                score += 0.3
            }
        }

        // Boost for tool recommendations when using related apps
        if candidate.category == .tool, let app = activeApp?.lowercased() {
            let developerApps = ["xcode", "vscode", "visual studio code", "jetbrains", "intellij",
                                 "pycharm", "webstorm", "terminal", "iterm", "sublime"]
            if developerApps.contains(where: { app.contains($0) }) {
                score += 0.2
            }
        }

        // Time-of-day relevance
        let hour = Calendar.current.component(.hour, from: Date())

        // Learning content works well in the morning
        if candidate.category == .learning && (hour >= 8 && hour < 12) {
            score += 0.1
        }

        // Workflow tips are good mid-day
        if candidate.category == .workflow && (hour >= 11 && hour < 16) {
            score += 0.1
        }

        // Exploration content fits afternoon/evening
        if candidate.category == .exploration && (hour >= 15 && hour < 20) {
            score += 0.1
        }

        return min(1.0, score)
    }

    // MARK: - Recency Penalty

    private func calculateRecencyPenalty(
        candidate: NotificationCandidate,
        db: DatabaseManager
    ) -> Double {
        // Check if a similar notification was sent recently
        // Extract key words from title for similarity check
        let keyWords = extractKeyWords(from: candidate.title)

        for keyWord in keyWords {
            if db.recentSimilarNotificationExists(
                category: candidate.category,
                titleSubstring: keyWord,
                withinHours: 24
            ) {
                return 0.8  // High penalty for recent similar notification
            }
        }

        // Check if any notification in this category was sent in the last 6 hours
        // This provides a softer penalty for category repetition
        // (Implementation would require a more granular query)

        return 0.0  // No penalty
    }

    /// Extract significant key words from a title for similarity matching.
    private func extractKeyWords(from title: String) -> [String] {
        let stopWords: Set<String> = ["the", "a", "an", "and", "or", "but", "in", "on", "at",
                                       "to", "for", "of", "with", "by", "from", "is", "are",
                                       "was", "were", "be", "been", "your", "you", "how", "what"]

        let words = title.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { word in
                word.count > 3 && !stopWords.contains(word)
            }

        // Return the most significant words (first 3)
        return Array(words.prefix(3))
    }
}
