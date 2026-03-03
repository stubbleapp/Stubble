import Foundation
import TaskMinerShared

/// Persists dashboard settings in a shared JSON file (~/Library/Application Support/Stubble/settings.json).
/// Delegates to `SettingsStore` (in TaskMinerShared) for the core read/write logic,
/// keeping that logic testable via `SettingsStoreTests`.
@MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    /// The underlying testable store from TaskMinerShared.
    private let store: SettingsStore?

    private init() {
        if let config = try? SharedConfiguration() {
            self.store = SettingsStore(filePath: config.settingsPath)
        } else {
            self.store = nil
        }
    }

    // MARK: - Convenience Accessors (delegate to SettingsStore)

    var geminiApiKey: String? {
        get { store?.geminiApiKey }
        set { store?.geminiApiKey = newValue }
    }

    var customPrompt: String? {
        get { store?.customPrompt }
        set { store?.customPrompt = newValue }
    }

    var granularity: TaskGranularity {
        get { store?.granularity ?? .medium }
        set { store?.granularity = newValue }
    }

    var showScreensTab: Bool {
        get { store?.showScreensTab ?? false }
        set { store?.showScreensTab = newValue }
    }

    var hasCompletedSetup: Bool {
        get { store?.hasCompletedSetup ?? false }
        set { store?.hasCompletedSetup = newValue }
    }

    var launchAtLogin: Bool {
        get { store?.launchAtLogin ?? true }
        set { store?.launchAtLogin = newValue }
    }

    var minAwayMinutes: Int {
        get { store?.minAwayMinutes ?? 15 }
        set { store?.minAwayMinutes = newValue }
    }

    /// User-configured content exclusion rules.
    /// Defaults to the built-in NSFW rule when no custom exclusions have been set.
    var exclusions: [String] {
        get { store?.exclusions ?? ["Exclude adult, explicit, or NSFW content"] }
        set { store?.exclusions = newValue }
    }

    var appearanceMode: AppearanceMode {
        get { store?.appearanceMode ?? .system }
        set { store?.appearanceMode = newValue }
    }

    var analyticsEnabled: Bool {
        get { store?.analyticsEnabled ?? true }
        set { store?.analyticsEnabled = newValue }
    }

    var wizardPage: Int {
        get { store?.wizardPage ?? 0 }
        set { store?.wizardPage = newValue }
    }

    // MARK: - Notification Settings

    var notificationsEnabled: Bool {
        get { store?.notificationsEnabled ?? true }
        set { store?.notificationsEnabled = newValue }
    }

    var notificationsDailyMax: Int {
        get { store?.notificationsDailyMax ?? 3 }
        set { store?.notificationsDailyMax = newValue }
    }

    var notificationsRequireIdle: Bool {
        get { store?.notificationsRequireIdle ?? true }
        set { store?.notificationsRequireIdle = newValue }
    }

    var notificationsQuietHoursEnabled: Bool {
        get { store?.notificationsQuietHoursEnabled ?? false }
        set { store?.notificationsQuietHoursEnabled = newValue }
    }

    var notificationsQuietHoursStart: Int {
        get { store?.notificationsQuietHoursStart ?? 22 }
        set { store?.notificationsQuietHoursStart = newValue }
    }

    var notificationsQuietHoursEnd: Int {
        get { store?.notificationsQuietHoursEnd ?? 8 }
        set { store?.notificationsQuietHoursEnd = newValue }
    }

    var notificationsEnabledCategories: Set<String> {
        get { store?.notificationsEnabledCategories ?? Set(["article", "tool", "best_practice", "workflow", "learning", "exploration"]) }
        set { store?.notificationsEnabledCategories = newValue }
    }

    var notificationsPreferChatPrompts: Bool {
        get { store?.notificationsPreferChatPrompts ?? false }
        set { store?.notificationsPreferChatPrompts = newValue }
    }

    var notificationsMinRelevanceScore: Double {
        get { store?.notificationsMinRelevanceScore ?? 0.6 }
        set { store?.notificationsMinRelevanceScore = newValue }
    }

    var notificationsLearningEnabled: Bool {
        get { store?.notificationsLearningEnabled ?? true }
        set { store?.notificationsLearningEnabled = newValue }
    }
}
