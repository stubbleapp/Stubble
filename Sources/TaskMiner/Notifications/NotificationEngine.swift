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
        // Load settings
        let settings = loadSettings(from: settingsPath)
        guard settings.notificationsEnabled else { return }

        // Check if we're in quiet hours
        if isInQuietHours(settings: settings) { return }

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

        // If require-idle is enabled, only proceed when user is idle
        if settings.requireIdle && !isIdle {
            Logger.debug("NotificationEngine: Skipping — user is active and require-idle is enabled")
            return
        }

        // Check for ignored notifications (1 hour window)
        await checkForIgnoredNotifications(db: db, settings: settings)

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
        guard settings.notificationsEnabled else { return }
        guard !isInQuietHours(settings: settings) else { return }

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

    private func evaluateAndDeliver(
        isIdle: Bool,
        activeApp: String?,
        currentProject: String?,
        db: DatabaseManager,
        settings: NotificationSettings
    ) async {
        // Generate candidates from today's recommendations
        let candidates = await candidateGenerator.generateCandidates(
            db: db,
            enabledCategories: settings.enabledCategories,
            preferChatPrompts: settings.preferChatPrompts
        )

        guard !candidates.isEmpty else {
            Logger.debug("NotificationEngine: No candidates available")
            return
        }

        // Score candidates with context
        let scoredCandidates = scorer.scoreAll(
            candidates: candidates,
            currentProject: currentProject,
            activeApp: activeApp,
            db: db,
            learningEnabled: settings.learningEnabled
        )

        // Filter by minimum relevance score
        let qualified = scoredCandidates.filter { $0.totalScore >= settings.minRelevanceScore }
        guard !qualified.isEmpty else {
            Logger.debug("NotificationEngine: No candidates passed minimum relevance threshold (\(settings.minRelevanceScore))")
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
    func recordClick(notificationId: String, db: DatabaseManager, settings: NotificationSettings) {
        db.updateNotificationEngagement(id: notificationId, engagement: .clicked)

        // Update category stats if learning is enabled
        guard settings.learningEnabled else { return }
        engagementTracker.recordEngagement(
            notificationId: notificationId,
            engagement: .clicked,
            db: db
        )
    }

    /// Called when a notification is dismissed (from the delivery scheduler delegate).
    func recordDismiss(notificationId: String, db: DatabaseManager, settings: NotificationSettings) {
        db.updateNotificationEngagement(id: notificationId, engagement: .dismissed)

        guard settings.learningEnabled else { return }
        engagementTracker.recordEngagement(
            notificationId: notificationId,
            engagement: .dismissed,
            db: db
        )
    }

    /// Check for notifications that were delivered more than 1 hour ago with no engagement.
    private func checkForIgnoredNotifications(db: DatabaseManager, settings: NotificationSettings) async {
        let cutoff = Date().addingTimeInterval(-3600)  // 1 hour ago
        let unengaged = db.notificationsWithoutEngagement(olderThan: cutoff)

        for notification in unengaged {
            db.updateNotificationEngagement(id: notification.id, engagement: .ignored)

            if settings.learningEnabled {
                engagementTracker.recordEngagement(
                    notificationId: notification.id,
                    engagement: .ignored,
                    db: db
                )
            }
        }
    }

    // MARK: - Settings & Helpers

    private func loadSettings(from path: URL) -> NotificationSettings {
        let store = SettingsStore(filePath: path)
        return NotificationSettings(
            notificationsEnabled: store.notificationsEnabled,
            dailyMax: store.notificationsDailyMax,
            requireIdle: store.notificationsRequireIdle,
            quietHoursEnabled: store.notificationsQuietHoursEnabled,
            quietHoursStart: store.notificationsQuietHoursStart,
            quietHoursEnd: store.notificationsQuietHoursEnd,
            enabledCategories: store.notificationsEnabledCategories,
            preferChatPrompts: store.notificationsPreferChatPrompts,
            minRelevanceScore: store.notificationsMinRelevanceScore,
            learningEnabled: store.notificationsLearningEnabled
        )
    }

    private func isInQuietHours(settings: NotificationSettings) -> Bool {
        guard settings.quietHoursEnabled else { return false }

        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)

        let start = settings.quietHoursStart
        let end = settings.quietHoursEnd

        // Handle overnight quiet hours (e.g., 22:00 - 08:00)
        if start > end {
            return hour >= start || hour < end
        } else {
            return hour >= start && hour < end
        }
    }
}

// MARK: - Settings Struct

/// Lightweight settings struct for notification configuration.
struct NotificationSettings {
    let notificationsEnabled: Bool
    let dailyMax: Int
    let requireIdle: Bool
    let quietHoursEnabled: Bool
    let quietHoursStart: Int
    let quietHoursEnd: Int
    let enabledCategories: Set<String>
    let preferChatPrompts: Bool
    let minRelevanceScore: Double
    let learningEnabled: Bool

    init(
        notificationsEnabled: Bool = true,
        dailyMax: Int = 3,
        requireIdle: Bool = true,
        quietHoursEnabled: Bool = false,
        quietHoursStart: Int = 22,
        quietHoursEnd: Int = 8,
        enabledCategories: Set<String> = Set(NotificationCategory.allCases.map { $0.rawValue }),
        preferChatPrompts: Bool = false,
        minRelevanceScore: Double = 0.6,
        learningEnabled: Bool = true
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.dailyMax = dailyMax
        self.requireIdle = requireIdle
        self.quietHoursEnabled = quietHoursEnabled
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.enabledCategories = enabledCategories
        self.preferChatPrompts = preferChatPrompts
        self.minRelevanceScore = minRelevanceScore
        self.learningEnabled = learningEnabled
    }
}
