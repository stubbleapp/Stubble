import Foundation

/// Represents an MCP client that has connected to Stubble.
public struct MCPClient: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let version: String?
    public let firstSeen: Date
    public var lastSeen: Date
    public var totalCalls: Int

    /// Whether this client has been seen within the last 7 days.
    public var isConnected: Bool {
        lastSeen > Date().addingTimeInterval(-7 * 24 * 60 * 60)
    }

    /// Human-readable time since last seen.
    public var lastSeenDescription: String {
        let interval = -lastSeen.timeIntervalSinceNow
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        } else {
            let days = Int(interval / 86400)
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
    }

    public init(name: String, version: String?, firstSeen: Date = Date(), lastSeen: Date = Date(), totalCalls: Int = 0) {
        self.name = name
        self.version = version
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.totalCalls = totalCalls
    }
}

/// Container for persisted MCP client data.
public struct MCPClientStore: Codable, Sendable {
    public var clients: [MCPClient]

    public init(clients: [MCPClient] = []) {
        self.clients = clients
    }
}
