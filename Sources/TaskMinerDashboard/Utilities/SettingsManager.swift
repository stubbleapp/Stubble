import Foundation
import TaskMinerShared

/// Persists dashboard settings in a shared JSON file (~/Library/Application Support/Stubble/settings.json).
@MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    private let filePath: URL?

    private init() {
        self.filePath = (try? SharedConfiguration())?.settingsPath
        migrateKeychainKeyIfNeeded()
    }

    /// One-time migration: move the API key from macOS Keychain to settings.json.
    /// After this, Keychain is never accessed again, eliminating permission prompts.
    private func migrateKeychainKeyIfNeeded() {
        // Skip if we already have a key in settings
        guard load().geminiApiKey == nil else { return }
        // Try to read from Keychain (covers both "Stubble" and legacy "TaskMiner" service names)
        if let keychainKey = GeminiKeychain.get(), !keychainKey.isEmpty {
            var settings = load()
            settings.geminiApiKey = keychainKey
            save(settings)
            // Clean up Keychain entries so no future prompts occur
            GeminiKeychain.set(nil)
        }
    }

    // MARK: - Settings Model

    struct Settings: Codable {
        var geminiApiKey: String?
        var customPrompt: String?
        var granularity: TaskGranularity?
        var showScreensTab: Bool?
        var hasCompletedSetup: Bool?
        var launchAtLogin: Bool?
    }

    // MARK: - Read / Write (for future file-based settings)

    func load() -> Settings {
        guard let filePath,
              FileManager.default.fileExists(atPath: filePath.path),
              let data = try? Data(contentsOf: filePath),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else {
            return Settings()
        }
        return settings
    }

    func save(_ settings: Settings) {
        guard let filePath else { return }
        let dir = filePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: filePath, options: .atomic)
        }
    }

    // MARK: - Gemini API key (stored in settings.json alongside other settings)

    var geminiApiKey: String? {
        get { load().geminiApiKey }
        set {
            var settings = load()
            settings.geminiApiKey = newValue
            save(settings)
        }
    }

    // MARK: - Custom prompt

    var customPrompt: String? {
        get { load().customPrompt }
        set {
            var settings = load()
            settings.customPrompt = newValue
            save(settings)
        }
    }

    // MARK: - Task Granularity

    var granularity: TaskGranularity {
        get { load().granularity ?? .medium }
        set {
            var settings = load()
            settings.granularity = newValue
            save(settings)
        }
    }

    // MARK: - Show Screens Tab

    var showScreensTab: Bool {
        get { load().showScreensTab ?? false }
        set {
            var settings = load()
            settings.showScreensTab = newValue
            save(settings)
        }
    }

    // MARK: - Setup Wizard

    var hasCompletedSetup: Bool {
        get { load().hasCompletedSetup ?? false }
        set {
            var settings = load()
            settings.hasCompletedSetup = newValue
            save(settings)
        }
    }

    // MARK: - Launch at Login

    var launchAtLogin: Bool {
        get { load().launchAtLogin ?? false }
        set {
            var settings = load()
            settings.launchAtLogin = newValue
            save(settings)
        }
    }
}
