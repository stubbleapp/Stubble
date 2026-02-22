import Foundation

public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum Logger {
    public static var minimumLevel: LogLevel = .info

    public static func log(_ level: LogLevel, _ message: String) {
        guard level >= minimumLevel else { return }
        let ts = SharedFormatters.iso8601.string(from: Date())
        fputs("[\(ts)] [\(level.label)] \(message)\n", stderr)
    }

    public static func debug(_ msg: String) { log(.debug, msg) }
    public static func info(_ msg: String) { log(.info, msg) }
    public static func warning(_ msg: String) { log(.warning, msg) }
    public static func error(_ msg: String) { log(.error, msg) }
}
