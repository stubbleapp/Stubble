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

    /// Optional log file handle. Call `Logger.enableFileLogging()` to write
    /// logs to ~/Library/Application Support/Stubble/stubble.log.
    /// The file is capped at ~2 MB and rotated automatically.
    private static var fileHandle: FileHandle?
    private static let fileLock = NSLock()
    private static let maxLogSize: UInt64 = 2 * 1024 * 1024  // 2 MB

    /// Start writing log lines to a file in the Stubble data directory.
    /// Safe to call multiple times; only opens the file once.
    public static func enableFileLogging() {
        fileLock.lock()
        defer { fileLock.unlock() }
        guard fileHandle == nil else { return }

        guard let config = try? SharedConfiguration() else { return }
        let logPath = config.dataDirectory.appendingPathComponent("stubble.log")
        let fm = FileManager.default

        // Create parent directory if needed
        try? fm.createDirectory(at: config.dataDirectory, withIntermediateDirectories: true)

        // Rotate if the log is too large
        if fm.fileExists(atPath: logPath.path),
           let attrs = try? fm.attributesOfItem(atPath: logPath.path),
           let size = attrs[.size] as? UInt64,
           size > maxLogSize {
            let oldPath = config.dataDirectory.appendingPathComponent("stubble.log.old")
            try? fm.removeItem(at: oldPath)
            try? fm.moveItem(at: logPath, to: oldPath)
        }

        // Create or open for appending
        if !fm.fileExists(atPath: logPath.path) {
            fm.createFile(atPath: logPath.path, contents: nil)
        }
        fileHandle = FileHandle(forWritingAtPath: logPath.path)
        fileHandle?.seekToEndOfFile()
    }

    public static func log(_ level: LogLevel, _ message: String) {
        guard level >= minimumLevel else { return }
        let ts = SharedFormatters.iso8601.string(from: Date())
        let line = "[\(ts)] [\(level.label)] \(message)\n"

        // Always write to stderr (visible when running from terminal)
        fputs(line, stderr)

        // Also write to log file if enabled
        fileLock.lock()
        if let fh = fileHandle, let data = line.data(using: .utf8) {
            fh.write(data)
        }
        fileLock.unlock()
    }

    public static func debug(_ msg: String) { log(.debug, msg) }
    public static func info(_ msg: String) { log(.info, msg) }
    public static func warning(_ msg: String) { log(.warning, msg) }
    public static func error(_ msg: String) { log(.error, msg) }
}
