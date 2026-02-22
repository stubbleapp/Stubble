import Foundation
import TaskMinerShared

/// Persists dashboard settings. Gemini API key is stored in Keychain; other settings in JSON.
@MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    private let filePath: URL?

    private init() {
        self.filePath = (try? SharedConfiguration())?.settingsPath
    }

    // MARK: - Settings Model (non-secret settings only; key is in Keychain)

    struct Settings: Codable {
        var customPrompt: String?
        var granularity: TaskGranularity?
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

    // MARK: - Gemini API key (Keychain)

    var geminiApiKey: String? {
        get { GeminiKeychain.get() }
        set { GeminiKeychain.set(newValue) }
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
}
