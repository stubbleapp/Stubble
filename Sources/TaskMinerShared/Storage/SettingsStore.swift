import Foundation

/// File-backed settings persistence that can be tested independently of SettingsManager.
/// Stores settings as JSON at a given file path with restricted (0600) permissions.
///
/// The dashboard's `SettingsManager` delegates to this class so the singleton
/// still works but the core logic is testable via the shared library.
public final class SettingsStore {

    /// The file URL where settings are persisted.
    public let filePath: URL

    /// In-memory cache to avoid disk reads on every access.
    private var cached: AppSettings?

    public init(filePath: URL) {
        self.filePath = filePath
    }

    // MARK: - Read / Write

    /// Load settings from disk (or return defaults if the file doesn't exist).
    public func load() -> AppSettings {
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
    @discardableResult
    public func save(_ settings: AppSettings) -> Bool {
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
    public func invalidateCache() {
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

    public init(
        geminiApiKey: String? = nil,
        customPrompt: String? = nil,
        granularity: TaskGranularity? = nil,
        showScreensTab: Bool? = nil,
        hasCompletedSetup: Bool? = nil,
        launchAtLogin: Bool? = nil
    ) {
        self.geminiApiKey = geminiApiKey
        self.customPrompt = customPrompt
        self.granularity = granularity
        self.showScreensTab = showScreensTab
        self.hasCompletedSetup = hasCompletedSetup
        self.launchAtLogin = launchAtLogin
    }
}
