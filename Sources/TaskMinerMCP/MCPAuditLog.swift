import Foundation

/// Audit logger for MCP tool invocations
public final class MCPAuditLog: @unchecked Sendable {
    public static let shared = MCPAuditLog()

    private let logFileURL: URL
    private let oldLogFileURL: URL
    private let maxLogSize: UInt64 = 10 * 1024 * 1024  // 10 MB
    private let queue = DispatchQueue(label: "com.stubble.mcp.audit")
    private var writeCount = 0
    private let checkRotationEvery = 100

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
                entry += " error=\"\(error.replacingOccurrences(of: "\"", with: "'"))\""
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
            let entry = "[\(timestamp)] auth_failure reason=\"\(reason)\"\n"
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
        // Convert to simple string representation, omitting sensitive values
        var parts: [String] = []
        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            switch value {
            case .string(let s):
                // Truncate long strings
                let truncated = s.count > 50 ? String(s.prefix(50)) + "..." : s
                parts.append("\(key):\"\(truncated)\"")
            case .int(let i):
                parts.append("\(key):\(i)")
            case .bool(let b):
                parts.append("\(key):\(b)")
            case .null:
                parts.append("\(key):null")
            default:
                parts.append("\(key):[...]")
            }
        }
        return "{\(parts.joined(separator: ", "))}"
    }
}
