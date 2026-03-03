import Foundation
import UserNotifications
import TaskMinerShared

/// Orchestrates the notification system: candidate generation, scoring, delivery, and engagement tracking.
/// Singleton that coordinates with the daemon's periodic check and idle transitions.
actor NotificationEngine {
    static let shared = NotificationEngine()

    private let candidateGenerator: NotificationCandidateGenerator
    private let scorer: NotificationRelevanceScorer
    private let scheduler: NotificationDeliveryScheduler
    private let engagementTracker: NotificationEngagementTracker

    /// Last time we evaluated candidates (15-minute batching window).
    private var lastEvaluationTime: Date = .distantPast

    /// Evaluation interval (15 minutes, synchronized with AI refresh cadence).
    private let evaluationInterval: TimeInterval = 900

    /// Whether we've delivered a notification today (for catch-up logic).
    private var hasDeliveredToday: Bool = false
    private var lastDeliveryDate: String = ""

    private init() {
        self.candidateGenerator = NotificationCandidateGenerator()
        self.scorer = NotificationRelevanceScorer()
        self.scheduler = NotificationDeliveryScheduler()
        self.engagementTracker = NotificationEngagementTracker()
    }

    // MARK: - Public Entry Points

    /// Called from periodicCheck() after summarization completes.
    /// Evaluates candidates every 15 minutes and delivers the best one if caps allow.
    func periodicEvaluation(
        isIdle: Bool,
        activeApp: String?,
        currentProject: String?,
        db: DatabaseManager,
        settingsPath: URL
    ) async {
        let settings = loadSettings(from: settingsPath)

        // Batching: only evaluate every 15 minutes
        let elapsed = Date().timeIntervalSince(lastEvaluationTime)
        guard elapsed >= evaluationInterval else { return }
        lastEvaluationTime = Date()

        // Check daily cap
        let dailyCount = db.notificationCountToday()
        guard dailyCount < settings.dailyMax else {
            Logger.debug("NotificationEngine: Daily cap reached (\(dailyCount)/\(settings.dailyMax))")
            return
        }

        // Only notify when user is idle (less intrusive)
        guard isIdle else {
            Logger.debug("NotificationEngine: Skipping — user is active")
            return
        }

        // Check for ignored notifications (1 hour window)
        await checkForIgnoredNotifications(db: db)

        // Generate and evaluate candidates
        await evaluateAndDeliver(
            isIdle: isIdle,
            activeApp: activeApp,
            currentProject: currentProject,
            db: db,
            settings: settings
        )
    }

    /// Called when the user becomes idle — a good opportunity to notify.
    func onIdleTransition(
        isIdle: Bool,
        activeApp: String?,
        currentProject: String?,
        db: DatabaseManager,
        settingsPath: URL
    ) async {
        guard isIdle else { return }  // Only trigger on becoming idle

        let settings = loadSettings(from: settingsPath)

        // Check daily cap
        let dailyCount = db.notificationCountToday()
        guard dailyCount < settings.dailyMax else { return }

        // Evaluate immediately on idle transition (bypass batching window)
        await evaluateAndDeliver(
            isIdle: isIdle,
            activeApp: activeApp,
            currentProject: currentProject,
            db: db,
            settings: settings
        )
    }

    // MARK: - Evaluation & Delivery

    /// Minimum relevance score for a notification to be delivered.
    private let minRelevanceScore: Double = 0.6

    private func evaluateAndDeliver(
        isIdle: Bool,
        activeApp: String?,
        currentProject: String?,
        db: DatabaseManager,
        settings: NotificationSettings
    ) async {
        // Generate candidates from today's recommendations (all categories enabled)
        let candidates = await candidateGenerator.generateCandidates(
            db: db,
            enabledCategories: Set(NotificationCategory.allCases.map { $0.rawValue }),
            preferChatPrompts: settings.preferChatPrompts
        )

        guard !candidates.isEmpty else {
            Logger.debug("NotificationEngine: No candidates available")
            return
        }

        // Score candidates with context (learning always enabled)
        let scoredCandidates = scorer.scoreAll(
            candidates: candidates,
            currentProject: currentProject,
            activeApp: activeApp,
            db: db,
            learningEnabled: true
        )

        // Filter by minimum relevance score
        let qualified = scoredCandidates.filter { $0.totalScore >= minRelevanceScore }
        guard !qualified.isEmpty else {
            Logger.debug("NotificationEngine: No candidates passed minimum relevance threshold (\(minRelevanceScore))")
            return
        }

        // Pick the best candidate
        guard let best = qualified.max(by: { $0.totalScore < $1.totalScore }) else { return }

        // Check per-category cap (max 1 per category per day)
        let categoryCount = db.notificationCountToday(category: best.category)
        guard categoryCount < 1 else {
            Logger.debug("NotificationEngine: Category '\(best.category.rawValue)' already has a notification today")
            return
        }

        // Check for suppressed categories (high ignore rate)
        let categoryStats = db.notificationCategoryStats(for: best.category)
        if categoryStats.shouldSuppress {
            Logger.debug("NotificationEngine: Category '\(best.category.rawValue)' is suppressed due to high ignore rate")
            return
        }

        // Deliver the notification
        let record = NotificationRecord(
            id: best.id,
            type: best.type,
            category: best.category,
            title: best.title,
            body: best.body,
            payload: best.payload,
            relevanceScore: best.totalScore,
            idleAtDelivery: isIdle,
            activeAppAtDelivery: activeApp
        )

        await scheduler.deliver(record)
        db.insertNotification(record)

        // Update category stats
        var stats = categoryStats
        stats.totalSent += 1
        stats.updatedAt = Date()
        db.updateNotificationCategoryStats(stats)

        // Track delivery for today
        let today = SharedFormatters.dayFormatter.string(from: Date())
        if lastDeliveryDate != today {
            hasDeliveredToday = false
            lastDeliveryDate = today
        }
        hasDeliveredToday = true

        Logger.info("NotificationEngine: Delivered notification '\(best.title)' (score: \(String(format: "%.2f", best.totalScore)))")
    }

    // MARK: - Engagement Tracking

    /// Called when a notification is clicked (from the delivery scheduler delegate).
    func recordClick(notificationId: String, db: DatabaseManager) {
        db.updateNotificationEngagement(id: notificationId, engagement: .clicked)
        engagementTracker.recordEngagement(
            notificationId: notificationId,
            engagement: .clicked,
            db: db
        )
    }

    /// Called when a notification is dismissed (from the delivery scheduler delegate).
    func recordDismiss(notificationId: String, db: DatabaseManager) {
        db.updateNotificationEngagement(id: notificationId, engagement: .dismissed)
        engagementTracker.recordEngagement(
            notificationId: notificationId,
            engagement: .dismissed,
            db: db
        )
    }

    /// Check for notifications that were delivered more than 1 hour ago with no engagement.
    private func checkForIgnoredNotifications(db: DatabaseManager) async {
        let cutoff = Date().addingTimeInterval(-3600)  // 1 hour ago
        let unengaged = db.notificationsWithoutEngagement(olderThan: cutoff)

        for notification in unengaged {
            db.updateNotificationEngagement(id: notification.id, engagement: .ignored)
            engagementTracker.recordEngagement(
                notificationId: notification.id,
                engagement: .ignored,
                db: db
            )
        }
    }

    // MARK: - Settings

    private func loadSettings(from path: URL) -> NotificationSettings {
        let store = SettingsStore(filePath: path)
        return NotificationSettings(
            dailyMax: store.notificationsDailyMax,
            preferChatPrompts: store.notificationsPreferChatPrompts
        )
    }
}

// MARK: - Settings Struct

/// Simplified settings struct — only user-configurable options.
struct NotificationSettings {
    let dailyMax: Int
    let preferChatPrompts: Bool

    init(dailyMax: Int = 3, preferChatPrompts: Bool = false) {
        self.dailyMax = dailyMax
        self.preferChatPrompts = preferChatPrompts
    }
}
