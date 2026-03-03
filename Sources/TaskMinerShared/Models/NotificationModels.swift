import Foundation

// MARK: - Notification Type

/// The action type for a notification — either opens a URL or pre-fills a chat prompt.
public enum NotificationType: String, Codable, Sendable {
    case link       // Opens a URL in the browser
    case chatPrompt // Opens the app with a pre-filled chat prompt
}

// MARK: - Notification Category

/// Categories for notifications, matching Recommendation.Category for consistency.
public enum NotificationCategory: String, Codable, CaseIterable, Sendable {
    case article = "article"
    case tool = "tool"
    case bestPractice = "best_practice"
    case workflow = "workflow"
    case learning = "learning"
    case exploration = "exploration"

    public var displayName: String {
        switch self {
        case .article: return "Articles"
        case .tool: return "Tools"
        case .bestPractice: return "Best Practices"
        case .workflow: return "Workflow"
        case .learning: return "Learning"
        case .exploration: return "Exploration"
        }
    }

    public var icon: String {
        switch self {
        case .article: return "doc.text"
        case .tool: return "wrench.and.screwdriver"
        case .bestPractice: return "lightbulb"
        case .workflow: return "arrow.triangle.branch"
        case .learning: return "book"
        case .exploration: return "sparkle.magnifyingglass"
        }
    }
}

// MARK: - Notification Engagement

/// The user's response to a delivered notification.
public enum NotificationEngagement: String, Codable, Sendable {
    case clicked    // User clicked/tapped the notification
    case dismissed  // User explicitly dismissed the notification
    case ignored    // No action within the tracking window (typically 1 hour)
}

// MARK: - Notification Record

/// A notification that has been delivered, including its delivery context and engagement outcome.
public struct NotificationRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let type: NotificationType
    public let category: NotificationCategory
    public let title: String
    public let body: String
    public let payload: NotificationPayload?
    public let relevanceScore: Double
    public let deliveredAt: Date
    public let idleAtDelivery: Bool
    public let activeAppAtDelivery: String?
    public var engagement: NotificationEngagement?
    public var engagedAt: Date?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        type: NotificationType,
        category: NotificationCategory,
        title: String,
        body: String,
        payload: NotificationPayload? = nil,
        relevanceScore: Double,
        deliveredAt: Date = Date(),
        idleAtDelivery: Bool,
        activeAppAtDelivery: String? = nil,
        engagement: NotificationEngagement? = nil,
        engagedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.category = category
        self.title = title
        self.body = body
        self.payload = payload
        self.relevanceScore = relevanceScore
        self.deliveredAt = deliveredAt
        self.idleAtDelivery = idleAtDelivery
        self.activeAppAtDelivery = activeAppAtDelivery
        self.engagement = engagement
        self.engagedAt = engagedAt
        self.createdAt = createdAt
    }
}

// MARK: - Notification Payload

/// The action payload for a notification — URL for links, prompt text for chat.
public struct NotificationPayload: Codable, Sendable {
    public let url: String?
    public let chatPrompt: String?

    public init(url: String? = nil, chatPrompt: String? = nil) {
        self.url = url
        self.chatPrompt = chatPrompt
    }
}

// MARK: - Notification Candidate

/// A candidate notification before delivery, with scoring inputs for relevance evaluation.
public struct NotificationCandidate: Sendable {
    public let id: String
    public let type: NotificationType
    public let category: NotificationCategory
    public let title: String
    public let body: String
    public let payload: NotificationPayload?

    // Scoring inputs
    public let contentRelevance: Double    // 0-1: How well it matches user profile/projects
    public let contextScore: Double        // 0-1: How well it matches current work
    public let urgency: Double             // 0-1: Time-sensitivity
    public let recencyPenalty: Double      // 0-1: Penalty for similar recent notifications

    /// The source of this candidate (e.g., "recommendation", "activity_insight", "time_based").
    public let source: String

    /// Optional reference to the source recommendation ID.
    public let sourceRecommendationId: String?

    public init(
        id: String = UUID().uuidString,
        type: NotificationType,
        category: NotificationCategory,
        title: String,
        body: String,
        payload: NotificationPayload? = nil,
        contentRelevance: Double,
        contextScore: Double,
        urgency: Double,
        recencyPenalty: Double,
        source: String,
        sourceRecommendationId: String? = nil
    ) {
        self.id = id
        self.type = type
        self.category = category
        self.title = title
        self.body = body
        self.payload = payload
        self.contentRelevance = contentRelevance
        self.contextScore = contextScore
        self.urgency = urgency
        self.recencyPenalty = recencyPenalty
        self.source = source
        self.sourceRecommendationId = sourceRecommendationId
    }

    /// Weighted total score (0-1). Higher is more relevant.
    public var totalScore: Double {
        let weights = (content: 0.40, context: 0.30, urgency: 0.15, recency: 0.15)
        return (contentRelevance * weights.content)
             + (contextScore * weights.context)
             + (urgency * weights.urgency)
             + ((1.0 - recencyPenalty) * weights.recency)
    }
}

// MARK: - Notification Category Stats

/// Per-category performance metrics used for learning-based scoring adjustments.
public struct NotificationCategoryStats: Codable, Sendable {
    public let category: NotificationCategory
    public var totalSent: Int
    public var totalClicked: Int
    public var totalDismissed: Int
    public var totalIgnored: Int
    public var confidence: Double  // Decays on ignores, boosts on clicks
    public var updatedAt: Date

    public init(
        category: NotificationCategory,
        totalSent: Int = 0,
        totalClicked: Int = 0,
        totalDismissed: Int = 0,
        totalIgnored: Int = 0,
        confidence: Double = 1.0,
        updatedAt: Date = Date()
    ) {
        self.category = category
        self.totalSent = totalSent
        self.totalClicked = totalClicked
        self.totalDismissed = totalDismissed
        self.totalIgnored = totalIgnored
        self.confidence = confidence
        self.updatedAt = updatedAt
    }

    /// Click rate as a percentage (0-1). Returns 0 if no notifications have been sent.
    public var clickRate: Double {
        guard totalSent > 0 else { return 0 }
        return Double(totalClicked) / Double(totalSent)
    }

    /// Ignore rate as a percentage (0-1). Returns 0 if no notifications have been sent.
    public var ignoreRate: Double {
        guard totalSent > 0 else { return 0 }
        return Double(totalIgnored) / Double(totalSent)
    }

    /// Whether this category should be suppressed due to high ignore rate.
    /// Requires at least 5 samples for reliable suppression.
    public var shouldSuppress: Bool {
        totalSent >= 5 && ignoreRate > 0.70
    }
}

// MARK: - Notification Daily Cap

/// Tracks daily notification counts per category.
public struct NotificationDailyCap: Codable, Sendable {
    public let date: String  // YYYY-MM-DD format
    public let category: NotificationCategory
    public var count: Int

    public init(date: String, category: NotificationCategory, count: Int = 0) {
        self.date = date
        self.category = category
        self.count = count
    }
}
