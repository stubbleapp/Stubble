import Foundation

/// Rate limiter for MCP requests (sliding window per minute)
public final class MCPRateLimiter: @unchecked Sendable {
    public static let shared = MCPRateLimiter()

    private var requestTimestamps: [Date] = []
    private let queue = DispatchQueue(label: "com.stubble.mcp.ratelimit")
    private let windowSeconds: TimeInterval = 60
    private let maxRequests: Int

    public init(maxRequestsPerMinute: Int = 60) {
        self.maxRequests = maxRequestsPerMinute
    }

    /// Check if a request is allowed. Returns true if allowed, false if rate limited.
    public func checkAndRecord() -> Bool {
        queue.sync {
            let now = Date()
            let windowStart = now.addingTimeInterval(-windowSeconds)

            // Remove timestamps outside the window
            requestTimestamps.removeAll { $0 < windowStart }

            // Check if we're at the limit
            if requestTimestamps.count >= maxRequests {
                return false
            }

            // Record this request
            requestTimestamps.append(now)
            return true
        }
    }

    /// Get remaining requests in current window
    public var remainingRequests: Int {
        queue.sync {
            let now = Date()
            let windowStart = now.addingTimeInterval(-windowSeconds)
            let recentCount = requestTimestamps.filter { $0 >= windowStart }.count
            return max(0, maxRequests - recentCount)
        }
    }

    /// Reset the rate limiter (for testing)
    public func reset() {
        queue.sync {
            requestTimestamps.removeAll()
        }
    }
}
