import Foundation
import TaskMinerShared

/// Tracks user engagement with notifications and updates category confidence scores.
/// Implements the learning loop that improves relevance over time.
struct NotificationEngagementTracker {

    /// Confidence adjustment factors
    private let clickBoost: Double = 0.05
    private let dismissPenalty: Double = 0.02
    private let ignorePenalty: Double = 0.08

    /// Minimum and maximum confidence bounds
    private let minConfidence: Double = 0.2
    private let maxConfidence: Double = 2.0

    /// Record an engagement event and update category stats.
    func recordEngagement(
        notificationId: String,
        engagement: NotificationEngagement,
        db: DatabaseManager
    ) {
        // First, find the notification to get its category
        guard let notification = findNotification(id: notificationId, db: db) else {
            Logger.warning("EngagementTracker: Notification not found: \(notificationId)")
            return
        }

        // Get current stats for the category
        var stats = db.notificationCategoryStats(for: notification.category)

        // Update engagement counters
        switch engagement {
        case .clicked:
            stats.totalClicked += 1
            stats.confidence = min(maxConfidence, stats.confidence + clickBoost)
            Logger.debug("EngagementTracker: Click recorded for '\(notification.category.rawValue)' — confidence: \(String(format: "%.2f", stats.confidence))")

        case .dismissed:
            stats.totalDismissed += 1
            stats.confidence = max(minConfidence, stats.confidence - dismissPenalty)
            Logger.debug("EngagementTracker: Dismiss recorded for '\(notification.category.rawValue)' — confidence: \(String(format: "%.2f", stats.confidence))")

        case .ignored:
            stats.totalIgnored += 1
            stats.confidence = max(minConfidence, stats.confidence - ignorePenalty)
            Logger.debug("EngagementTracker: Ignore recorded for '\(notification.category.rawValue)' — confidence: \(String(format: "%.2f", stats.confidence))")

            // Check for fatigue suppression
            if stats.shouldSuppress {
                Logger.info("EngagementTracker: Category '\(notification.category.rawValue)' now suppressed due to high ignore rate")
            }
        }

        // Persist updated stats
        stats.updatedAt = Date()
        db.updateNotificationCategoryStats(stats)

        // Apply fatigue detection
        applyFatigueDetection(stats: &stats, db: db)
    }

    // MARK: - Fatigue Detection

    /// Apply additional suppression if ignore rate is very high.
    private func applyFatigueDetection(stats: inout NotificationCategoryStats, db: DatabaseManager) {
        // If ignore rate exceeds 70% with sufficient samples, halve confidence
        if stats.totalSent >= 5 && stats.ignoreRate > 0.70 {
            let newConfidence = max(minConfidence, stats.confidence * 0.5)
            if newConfidence != stats.confidence {
                stats.confidence = newConfidence
                stats.updatedAt = Date()
                db.updateNotificationCategoryStats(stats)
                Logger.info("EngagementTracker: Fatigue suppression applied to '\(stats.category.rawValue)' — confidence halved to \(String(format: "%.2f", stats.confidence))")
            }
        }
    }

    // MARK: - Helpers

    private func findNotification(id: String, db: DatabaseManager) -> NotificationRecord? {
        // Query the database for the notification
        // For now, we rely on the caller having the category info
        // This is a simplified implementation
        return nil
    }

    /// Reset category stats (used when user clears learning data).
    func resetStats(db: DatabaseManager) {
        for category in NotificationCategory.allCases {
            let freshStats = NotificationCategoryStats(category: category)
            db.updateNotificationCategoryStats(freshStats)
        }
        Logger.info("EngagementTracker: All category stats reset")
    }

    /// Get a summary of category performance for the settings UI.
    func getCategorySummary(db: DatabaseManager) -> [CategoryPerformance] {
        return NotificationCategory.allCases.map { category in
            let stats = db.notificationCategoryStats(for: category)
            return CategoryPerformance(
                category: category,
                totalSent: stats.totalSent,
                clickRate: stats.clickRate,
                ignoreRate: stats.ignoreRate,
                confidence: stats.confidence,
                isSuppressed: stats.shouldSuppress
            )
        }
    }
}

// MARK: - Category Performance Summary

/// Performance summary for a notification category (used in settings UI).
struct CategoryPerformance {
    let category: NotificationCategory
    let totalSent: Int
    let clickRate: Double
    let ignoreRate: Double
    let confidence: Double
    let isSuppressed: Bool

    var displayClickRate: String {
        guard totalSent > 0 else { return "—" }
        return "\(Int(clickRate * 100))%"
    }

    var displayIgnoreRate: String {
        guard totalSent > 0 else { return "—" }
        return "\(Int(ignoreRate * 100))%"
    }

    var statusDescription: String {
        if isSuppressed {
            return "Suppressed"
        } else if confidence > 1.0 {
            return "High engagement"
        } else if confidence < 0.5 {
            return "Low engagement"
        } else {
            return "Normal"
        }
    }
}
