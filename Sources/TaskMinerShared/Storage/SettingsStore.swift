import Foundation

/// File-backed settings persistence that can be tested independently of SettingsManager.
/// Stores settings as JSON at a given file path with restricted (0600) permissions.
///
/// The dashboard's `SettingsManager` delegates to this class so the singleton
/// still works but the core logic is testable via the shared library.
/// Thread-safe via internal lock.
public final class SettingsStore {

    /// The file URL where settings are persisted.
    public let filePath: URL

    /// Lock for thread-safe cache access.
    private let lock = NSLock()

    /// In-memory cache to avoid disk reads on every access.
    private var cached: AppSettings?

    public init(filePath: URL) {
        self.filePath = filePath
    }

    // MARK: - Read / Write

    /// Load settings from disk (or return defaults if the file doesn't exist).
    /// Thread-safe.
    public func load() -> AppSettings {
        lock.lock()
        defer { lock.unlock() }

        if let cached { return cached }

        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return AppSettings()
        }
        do {
            let data = try Data(contentsOf: filePath)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            cached = settings
            return settings
        } catch {
            return AppSettings()
        }
    }

    /// Save settings to disk, creating the parent directory if needed.
    /// Sets file permissions to 0600 (owner-only) to protect the API key.
    /// Thread-safe.
    @discardableResult
    public func save(_ settings: AppSettings) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let dir = filePath.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: filePath, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: filePath.path
            )
            cached = settings
            return true
        } catch {
            return false
        }
    }

    /// Invalidate the in-memory cache so the next `load()` reads from disk.
    /// Thread-safe.
    public func invalidateCache() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    // MARK: - Convenience Accessors

    public var geminiApiKey: String? {
        get { load().geminiApiKey }
        set { update { $0.geminiApiKey = newValue } }
    }

    public var customPrompt: String? {
        get { load().customPrompt }
        set { update { $0.customPrompt = newValue } }
    }

    public var granularity: TaskGranularity {
        get { load().granularity ?? .medium }
        set { update { $0.granularity = newValue } }
    }

    public var showScreensTab: Bool {
        get { load().showScreensTab ?? false }
        set { update { $0.showScreensTab = newValue } }
    }

    public var hasCompletedSetup: Bool {
        get { load().hasCompletedSetup ?? false }
        set { update { $0.hasCompletedSetup = newValue } }
    }

    public var launchAtLogin: Bool {
        get { load().launchAtLogin ?? true }
        set { update { $0.launchAtLogin = newValue } }
    }

    public var minAwayMinutes: Int {
        get { load().minAwayMinutes ?? 15 }
        set { update { $0.minAwayMinutes = newValue } }
    }

    public var exclusions: [String]? {
        get { load().exclusions }
        set { update { $0.exclusions = newValue } }
    }

    public var appearanceMode: AppearanceMode {
        get { load().appearanceMode ?? .system }
        set { update { $0.appearanceMode = newValue } }
    }

    public var analyticsEnabled: Bool {
        get { load().analyticsEnabled ?? true }
        set { update { $0.analyticsEnabled = newValue } }
    }

    public var wizardPage: Int {
        get { load().wizardPage ?? 0 }
        set { update { $0.wizardPage = newValue } }
    }

    public var dayWrapHour: Int {
        get { load().dayWrapHour ?? 18 }
        set { update { $0.dayWrapHour = newValue } }
    }

    // MARK: - Notification Settings

    public var notificationsEnabled: Bool {
        get { load().notificationsEnabled ?? true }
        set { update { $0.notificationsEnabled = newValue } }
    }

    public var notificationsDailyMax: Int {
        get { load().notificationsDailyMax ?? 3 }
        set { update { $0.notificationsDailyMax = newValue } }
    }

    public var notificationsRequireIdle: Bool {
        get { load().notificationsRequireIdle ?? true }
        set { update { $0.notificationsRequireIdle = newValue } }
    }

    public var notificationsQuietHoursEnabled: Bool {
        get { load().notificationsQuietHoursEnabled ?? false }
        set { update { $0.notificationsQuietHoursEnabled = newValue } }
    }

    public var notificationsQuietHoursStart: Int {
        get { load().notificationsQuietHoursStart ?? 22 }
        set { update { $0.notificationsQuietHoursStart = newValue } }
    }

    public var notificationsQuietHoursEnd: Int {
        get { load().notificationsQuietHoursEnd ?? 8 }
        set { update { $0.notificationsQuietHoursEnd = newValue } }
    }

    public var notificationsEnabledCategories: Set<String> {
        get { Set(load().notificationsEnabledCategories ?? NotificationCategory.allCases.map { $0.rawValue }) }
        set { update { $0.notificationsEnabledCategories = Array(newValue) } }
    }

    public var notificationsPreferChatPrompts: Bool {
        get { load().notificationsPreferChatPrompts ?? false }
        set { update { $0.notificationsPreferChatPrompts = newValue } }
    }

    public var notificationsMinRelevanceScore: Double {
        get { load().notificationsMinRelevanceScore ?? 0.6 }
        set { update { $0.notificationsMinRelevanceScore = newValue } }
    }

    public var notificationsLearningEnabled: Bool {
        get { load().notificationsLearningEnabled ?? true }
        set { update { $0.notificationsLearningEnabled = newValue } }
    }

    // MARK: - Helpers

    private func update(_ mutate: (inout AppSettings) -> Void) {
        var settings = load()
        mutate(&settings)
        save(settings)
    }
}

// MARK: - Settings Model

/// Codable settings struct shared between SettingsStore and SettingsManager.
/// Matches the JSON schema of `~/Library/Application Support/Stubble/settings.json`.
public struct AppSettings: Codable, Equatable {
    public var geminiApiKey: String?
    public var customPrompt: String?
    public var granularity: TaskGranularity?
    public var showScreensTab: Bool?
    public var hasCompletedSetup: Bool?
    public var launchAtLogin: Bool?
    public var minAwayMinutes: Int?
    /// User-configured content exclusion rules (e.g. "Exclude adult content").
    /// When nil, defaults are applied by SettingsManager.
    public var exclusions: [String]?
    public var appearanceMode: AppearanceMode?
    public var analyticsEnabled: Bool?
    /// Current wizard page (0-3) for resuming setup after quit/reopen.
    public var wizardPage: Int?
    /// Hour (0-23) at which the current day switches to "Day Wrap" view (default: 18 = 6pm).
    public var dayWrapHour: Int?

    // MARK: - Notification Settings

    /// Whether notifications are enabled (default: true).
    public var notificationsEnabled: Bool?
    /// Maximum notifications per day (default: 3, range 1-5).
    public var notificationsDailyMax: Int?
    /// Only notify when user is idle (default: true).
    public var notificationsRequireIdle: Bool?
    /// Whether quiet hours are enabled (default: false).
    public var notificationsQuietHoursEnabled: Bool?
    /// Quiet hours start hour 0-23 (default: 22).
    public var notificationsQuietHoursStart: Int?
    /// Quiet hours end hour 0-23 (default: 8).
    public var notificationsQuietHoursEnd: Int?
    /// Enabled notification categories (raw values, default: all).
    public var notificationsEnabledCategories: [String]?
    /// Prefer chat prompts over links (default: false).
    public var notificationsPreferChatPrompts: Bool?
    /// Minimum relevance score to deliver (default: 0.6, range 0.4-0.9).
    public var notificationsMinRelevanceScore: Double?
    /// Allow engagement-based learning (default: true).
    public var notificationsLearningEnabled: Bool?

    public init(
        geminiApiKey: String? = nil,
        customPrompt: String? = nil,
        granularity: TaskGranularity? = nil,
        showScreensTab: Bool? = nil,
        hasCompletedSetup: Bool? = nil,
        launchAtLogin: Bool? = nil,
        minAwayMinutes: Int? = nil,
        exclusions: [String]? = nil,
        appearanceMode: AppearanceMode? = nil,
        analyticsEnabled: Bool? = nil,
        wizardPage: Int? = nil,
        dayWrapHour: Int? = nil,
        notificationsEnabled: Bool? = nil,
        notificationsDailyMax: Int? = nil,
        notificationsRequireIdle: Bool? = nil,
        notificationsQuietHoursEnabled: Bool? = nil,
        notificationsQuietHoursStart: Int? = nil,
        notificationsQuietHoursEnd: Int? = nil,
        notificationsEnabledCategories: [String]? = nil,
        notificationsPreferChatPrompts: Bool? = nil,
        notificationsMinRelevanceScore: Double? = nil,
        notificationsLearningEnabled: Bool? = nil
    ) {
        self.geminiApiKey = geminiApiKey
        self.customPrompt = customPrompt
        self.granularity = granularity
        self.showScreensTab = showScreensTab
        self.hasCompletedSetup = hasCompletedSetup
        self.launchAtLogin = launchAtLogin
        self.minAwayMinutes = minAwayMinutes
        self.exclusions = exclusions
        self.appearanceMode = appearanceMode
        self.analyticsEnabled = analyticsEnabled
        self.wizardPage = wizardPage
        self.dayWrapHour = dayWrapHour
        self.notificationsEnabled = notificationsEnabled
        self.notificationsDailyMax = notificationsDailyMax
        self.notificationsRequireIdle = notificationsRequireIdle
        self.notificationsQuietHoursEnabled = notificationsQuietHoursEnabled
        self.notificationsQuietHoursStart = notificationsQuietHoursStart
        self.notificationsQuietHoursEnd = notificationsQuietHoursEnd
        self.notificationsEnabledCategories = notificationsEnabledCategories
        self.notificationsPreferChatPrompts = notificationsPreferChatPrompts
        self.notificationsMinRelevanceScore = notificationsMinRelevanceScore
        self.notificationsLearningEnabled = notificationsLearningEnabled
    }
}
