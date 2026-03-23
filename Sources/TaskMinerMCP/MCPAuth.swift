import Foundation
import Security

/// Manages API key authentication for MCP server
public final class MCPAuth: @unchecked Sendable {
    public static let shared = MCPAuth()

    private let keyFileURL: URL
    private let keyPrefix = "sk-stubble-"
    private var cachedKey: String?
    private let queue = DispatchQueue(label: "com.stubble.mcp.auth")

    private init() {
        // Store key in ~/.stubble/mcp-key
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let stubbleDir = homeDir.appendingPathComponent(".stubble")
        self.keyFileURL = stubbleDir.appendingPathComponent("mcp-key")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: stubbleDir, withIntermediateDirectories: true)
    }

    /// Validate an API key from a request
    public func validateKey(_ providedKey: String) -> Bool {
        queue.sync {
            guard let storedKey = loadOrGenerateKey() else { return false }
            // Constant-time comparison to prevent timing attacks
            return constantTimeCompare(providedKey, storedKey)
        }
    }

    /// Get the current API key (generates one if none exists)
    public func getKey() -> String? {
        queue.sync {
            loadOrGenerateKey()
        }
    }

    /// Rotate the API key (invalidates all existing connections)
    public func rotateKey() -> String? {
        queue.sync {
            let newKey = generateKey()
            if saveKey(newKey) {
                cachedKey = newKey
                return newKey
            }
            return nil
        }
    }

    /// Check if an API key exists
    public var hasKey: Bool {
        queue.sync {
            FileManager.default.fileExists(atPath: keyFileURL.path)
        }
    }

    // MARK: - Private

    private func loadOrGenerateKey() -> String? {
        // Return cached key if available
        if let cached = cachedKey {
            return cached
        }

        // Try to load from file
        if let key = loadKeyFromFile() {
            cachedKey = key
            return key
        }

        // Generate new key
        let newKey = generateKey()
        if saveKey(newKey) {
            cachedKey = newKey
            return newKey
        }

        return nil
    }

    private func loadKeyFromFile() -> String? {
        guard FileManager.default.fileExists(atPath: keyFileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: keyFileURL)
            let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Validate key format
            if let key = key, key.hasPrefix(keyPrefix), key.count == keyPrefix.count + 32 {
                return key
            }
            return nil
        } catch {
            return nil
        }
    }

    private func generateKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let base64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
        // Take first 32 chars for a clean key
        let suffix = String(base64.prefix(32))
        return keyPrefix + suffix
    }

    private func saveKey(_ key: String) -> Bool {
        do {
            let data = key.data(using: .utf8)!
            try data.write(to: keyFileURL, options: .atomic)
            // Set file permissions to 0600 (owner read/write only)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keyFileURL.path
            )
            return true
        } catch {
            return false
        }
    }

    /// Constant-time string comparison to prevent timing attacks
    private func constantTimeCompare(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)

        guard aBytes.count == bBytes.count else { return false }

        var result: UInt8 = 0
        for (aByte, bByte) in zip(aBytes, bBytes) {
            result |= aByte ^ bByte
        }
        return result == 0
    }
}
