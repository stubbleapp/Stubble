import Foundation
import TaskMinerShared

/// Persists dashboard settings in a shared JSON file (~/Library/Application Support/Stubble/settings.json).
/// Caches settings in memory to avoid disk I/O on every property access.
@MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    private let filePath: URL?
    /// In-memory cache — avoids reading from disk on every property access.
    private var cached: Settings?

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
            // Only clean up Keychain after confirming the key was persisted to settings.json
            if load().geminiApiKey != nil {
                GeminiKeychain.set(nil)
            } else {
                Logger.warning("SettingsManager: keychain migration — save failed, keeping keychain entry")
            }
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

    // MARK: - Read / Write

    func load() -> Settings {
        if let cached { return cached }

        guard let filePath,
              FileManager.default.fileExists(atPath: filePath.path)
        else {
            return Settings()
        }
        do {
            let data = try Data(contentsOf: filePath)
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            cached = settings
            return settings
        } catch {
            Logger.warning("SettingsManager: failed to load settings: \(error.localizedDescription)")
            return Settings()
        }
    }

    func save(_ settings: Settings) {
        guard let filePath else { return }
        let dir = filePath.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Logger.warning("SettingsManager: failed to create directory: \(error.localizedDescription)")
        }
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: filePath, options: .atomic)
            // Restrict permissions to owner-only (0600) since the file may contain the API key
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath.path)
            cached = settings
        } catch {
            Logger.warning("SettingsManager: failed to save settings: \(error.localizedDescription)")
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
