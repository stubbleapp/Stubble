import Foundation
import TelemetryDeck
import TaskMinerShared

/// Lightweight wrapper around TelemetryDeck for Stubble analytics.
/// All event names are defined here so they stay consistent and discoverable.
enum Analytics {

    /// Initialize TelemetryDeck. Call once at app startup.
    /// The app ID is read from Info.plist (TelemetryDeckAppID) so it's not hardcoded in source.
    static func initialize() {
        guard let appID = Bundle.main.infoDictionary?["TelemetryDeckAppID"] as? String, !appID.isEmpty else {
            Logger.warning("TelemetryDeck app ID not found in Info.plist — analytics disabled")
            return
        }
        let config = TelemetryDeck.Config(appID: appID)
        TelemetryDeck.initialize(config: config)
    }

    /// Whether the user has opted in to anonymous usage data.
    /// Reads from SettingsStore directly to avoid @MainActor constraint on SettingsManager.
    private static var isEnabled: Bool {
        guard let config = try? SharedConfiguration() else { return true }
        return SettingsStore(filePath: config.settingsPath).analyticsEnabled
    }

    // MARK: - App Lifecycle

    static func appLaunched() {
        guard isEnabled else { return }
        TelemetryDeck.signal("app.launched")
    }

    static func setupCompleted() {
        guard isEnabled else { return }
        TelemetryDeck.signal("setup.completed")
    }

    // MARK: - Core Features

    static func summaryGenerated(taskCount: Int) {
        guard isEnabled else { return }
        TelemetryDeck.signal("summary.generated", parameters: [
            "taskCount": "\(taskCount)"
        ])
    }

    static func summaryFailed() {
        guard isEnabled else { return }
        TelemetryDeck.signal("summary.failed")
    }

    static func activitiesGenerated(projectCount: Int) {
        guard isEnabled else { return }
        TelemetryDeck.signal("activities.generated", parameters: [
            "projectCount": "\(projectCount)"
        ])
    }

    static func chatMessageSent() {
        guard isEnabled else { return }
        TelemetryDeck.signal("chat.messageSent")
    }

    static func recommendationsGenerated(count: Int) {
        guard isEnabled else { return }
        TelemetryDeck.signal("recommendations.generated", parameters: [
            "count": "\(count)"
        ])
    }

    static func csvExported(taskCount: Int) {
        guard isEnabled else { return }
        TelemetryDeck.signal("csv.exported", parameters: [
            "taskCount": "\(taskCount)"
        ])
    }

    // MARK: - Settings

    static func settingChanged(_ setting: String, value: String) {
        guard isEnabled else { return }
        TelemetryDeck.signal("setting.changed", parameters: [
            "setting": setting,
            "value": value
        ])
    }

    // MARK: - Monitoring

    static func monitoringPaused(duration: String) {
        guard isEnabled else { return }
        TelemetryDeck.signal("monitoring.paused", parameters: [
            "duration": duration
        ])
    }

    static func monitoringResumed() {
        guard isEnabled else { return }
        TelemetryDeck.signal("monitoring.resumed")
    }

    // MARK: - Data Management

    static func dataClearedByUser() {
        guard isEnabled else { return }
        TelemetryDeck.signal("data.cleared")
    }
}
