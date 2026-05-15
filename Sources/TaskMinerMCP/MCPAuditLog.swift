import Foundation
import TaskMinerShared

/// Audit logger for MCP tool invocations
public final class MCPAuditLog: @unchecked Sendable {
    public static let shared = MCPAuditLog()

    private let logFileURL: URL
    private let oldLogFileURL: URL
    private let clientsFileURL: URL
    private let maxLogSize: UInt64 = 10 * 1024 * 1024  // 10 MB
    private let queue = DispatchQueue(label: "com.stubble.mcp.audit")
    private var writeCount = 0
    private let checkRotationEvery = 100

    /// In-memory cache of connected clients
    private var clientsCache: [String: MCPClient] = [:]
    private var clientsCacheLoaded = false

    private lazy var dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let stubbleDir = homeDir.appendingPathComponent(".stubble")
        self.logFileURL = stubbleDir.appendingPathComponent("mcp-audit.log")
        self.oldLogFileURL = stubbleDir.appendingPathComponent("mcp-audit.log.old")
        self.clientsFileURL = stubbleDir.appendingPathComponent("mcp-clients.json")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: stubbleDir, withIntermediateDirectories: true)
    }

    /// Log a tool invocation
    public func logToolCall(
        tool: String,
        params: [String: JSONValue]?,
        resultRows: Int?,
        durationMs: Int,
        error: String? = nil
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let timestamp = self.dateFormatter.string(from: Date())
            var entry = "[\(timestamp)] tool=\(tool)"

            // Add params (sanitized)
            if let params = params, !params.isEmpty {
                let sanitizedParams = self.sanitizeParams(params)
                entry += " params=\(sanitizedParams)"
            }

            // Add result info
            if let rows = resultRows {
                entry += " rows=\(rows)"
            }

            entry += " duration_ms=\(durationMs)"

            if let error = error {
                // Sanitize and escape error message to prevent log injection
                let sanitizedError = DataSanitizer.sanitize(error)
                let escapedError = self.escapeLogValue(sanitizedError)
                let truncatedError = escapedError.count > 200 ? String(escapedError.prefix(200)) + "..." : escapedError
                entry += " error=\"\(truncatedError)\""
            }

            entry += "\n"

            self.writeEntry(entry)
        }
    }

    /// Log an auth failure
    public func logAuthFailure(reason: String) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let timestamp = self.dateFormatter.string(from: Date())
            let escapedReason = self.escapeLogValue(reason)
            let entry = "[\(timestamp)] auth_failure reason=\"\(escapedReason)\"\n"
            self.writeEntry(entry)
        }
    }

    /// Log rate limiting
    public func logRateLimited() {
        queue.async { [weak self] in
            guard let self = self else { return }

            let timestamp = self.dateFormatter.string(from: Date())
            let entry = "[\(timestamp)] rate_limited\n"
            self.writeEntry(entry)
        }
    }

    /// Get recent log entries (for settings UI)
    public func recentEntries(limit: Int = 50) -> [String] {
        queue.sync {
            guard let data = try? Data(contentsOf: logFileURL),
                  let content = String(data: data, encoding: .utf8) else {
                return []
            }

            let lines = content.components(separatedBy: "\n")
                .filter { !$0.isEmpty }

            return Array(lines.suffix(limit))
        }
    }

    // MARK: - Client Tracking

    /// Log a client connection from the MCP initialize request.
    /// Updates existing client or creates a new entry.
    public func logClientConnection(name: String, version: String?) {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.loadClientsIfNeeded()

            let now = Date()
            if var existing = self.clientsCache[name] {
                existing.lastSeen = now
                self.clientsCache[name] = existing
            } else {
                let client = MCPClient(name: name, version: version, firstSeen: now, lastSeen: now, totalCalls: 0)
                self.clientsCache[name] = client
            }

            self.saveClients()
        }
    }

    /// Increment the tool call count for a client.
    public func incrementClientCalls(name: String) {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.loadClientsIfNeeded()

            if var existing = self.clientsCache[name] {
                existing.totalCalls += 1
                existing.lastSeen = Date()
                self.clientsCache[name] = existing
                self.saveClients()
            }
        }
    }

    /// Load all connected clients.
    public func loadConnectedClients() -> [MCPClient] {
        queue.sync {
            loadClientsIfNeeded()
            return Array(clientsCache.values).sorted { $0.lastSeen > $1.lastSeen }
        }
    }

    private func loadClientsIfNeeded() {
        guard !clientsCacheLoaded else { return }
        clientsCacheLoaded = true

        guard FileManager.default.fileExists(atPath: clientsFileURL.path),
              let data = try? Data(contentsOf: clientsFileURL),
              let store = try? JSONDecoder().decode(MCPClientStore.self, from: data) else {
            return
        }

        for client in store.clients {
            clientsCache[client.name] = client
        }
    }

    private func saveClients() {
        let store = MCPClientStore(clients: Array(clientsCache.values))
        guard let data = try? JSONEncoder().encode(store) else { return }

        do {
            try data.write(to: clientsFileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: clientsFileURL.path
            )
        } catch {
            Logger.error("MCPAuditLog: Failed to save clients: \(error)")
        }
    }

    // MARK: - Private

    private func writeEntry(_ entry: String) {
        guard let data = entry.data(using: .utf8) else { return }

        // Create file if needed
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: logFileURL.path
            )
        }

        // Append to file
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }

        // Check rotation periodically
        writeCount += 1
        if writeCount >= checkRotationEvery {
            writeCount = 0
            rotateIfNeeded()
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxLogSize else {
            return
        }

        // Delete old log if exists
        try? FileManager.default.removeItem(at: oldLogFileURL)

        // Move current to old
        try? FileManager.default.moveItem(at: logFileURL, to: oldLogFileURL)
    }

    private func sanitizeParams(_ params: [String: JSONValue]) -> String {
        // Convert to simple string representation with proper sanitization
        var parts: [String] = []
        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            // Sanitize key to prevent injection
            let safeKey = escapeLogValue(key)
            switch value {
            case .string(let s):
                // Apply DataSanitizer to redact sensitive patterns, then truncate
                let sanitized = DataSanitizer.sanitize(s)
                let truncated = sanitized.count > 50 ? String(sanitized.prefix(50)) + "..." : sanitized
                let escaped = escapeLogValue(truncated)
                parts.append("\(safeKey):\"\(escaped)\"")
            case .int(let i):
                parts.append("\(safeKey):\(i)")
            case .bool(let b):
                parts.append("\(safeKey):\(b)")
            case .null:
                parts.append("\(safeKey):null")
            default:
                parts.append("\(safeKey):[...]")
            }
        }
        return "{\(parts.joined(separator: ", "))}"
    }

    /// Escape special characters to prevent log injection
    private func escapeLogValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
