import Foundation
import Security

/// Stores and retrieves the Gemini API key in the Keychain (macOS).
/// Used by both the Dashboard and the CLI so one saved key works everywhere.
public enum GeminiKeychain {
    private static let service = "Stubble.GeminiAPI"
    private static let account = "apiKey"

    /// Previous service name — used for one-time migration from the old "TaskMiner" keychain entry.
    private static let legacyService = "TaskMiner.GeminiAPI"

    /// Returns the stored API key, or nil if not set or on error.
    /// On first call after rename, migrates the key from the old "TaskMiner" service.
    public static func get() -> String? {
        if let key = read(service: service) {
            return key
        }
        // One-time migration: read from the legacy service and copy to the new one
        if let legacyKey = read(service: legacyService) {
            set(legacyKey)
            // Only delete legacy entry if the new one was written successfully
            if read(service: service) != nil {
                deleteLegacy()
            }
            return legacyKey
        }
        return nil
    }

    /// Read a key from a specific keychain service.
    private static func read(service svc: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else {
            return nil
        }
        return key
    }

    /// Saves the API key to the Keychain. Pass nil to delete.
    public static func set(_ value: String?) {
        delete()

        guard let value = value, !value.isEmpty,
              let data = value.data(using: .utf8)
        else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Remove the legacy "TaskMiner" keychain entry after migration.
    private static func deleteLegacy() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
