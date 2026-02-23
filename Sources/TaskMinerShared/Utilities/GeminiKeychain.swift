import Foundation
import Security

/// Stores and retrieves the Gemini API key in the Keychain (macOS).
/// Used by both the Dashboard and the CLI so one saved key works everywhere.
public enum GeminiKeychain {
    private static let service = "Stubble.GeminiAPI"
    private static let account = "apiKey"

    /// Returns the stored API key, or nil if not set or on error.
    public static func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
}
