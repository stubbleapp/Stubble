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

    /// Hour (0-23) at which the current day switches to "Day Wrap" view.
    var dayWrapHour: Int {
        get { store?.dayWrapHour ?? 18 }
        set { store?.dayWrapHour = newValue }
    }

    // MARK: - MCP Settings

    var mcpEnabled: Bool {
        get { store?.mcpEnabled ?? false }
        set { store?.mcpEnabled = newValue }
    }
}
