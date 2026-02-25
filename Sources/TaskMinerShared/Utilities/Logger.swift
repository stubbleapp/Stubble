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
    private static var logPath: URL?
    private static var dataDir: URL?
    private static let fileLock = NSLock()
    private static let maxLogSize: UInt64 = 2 * 1024 * 1024  // 2 MB
    /// Check file size every N writes to avoid stat() on every log line.
    private static var writesSinceRotationCheck: Int = 0
    private static let rotationCheckInterval: Int = 200

    /// Start writing log lines to a file in the Stubble data directory.
    /// Safe to call multiple times; only opens the file once.
    public static func enableFileLogging() {
        fileLock.lock()
        defer { fileLock.unlock() }
        guard fileHandle == nil else { return }

        guard let config = try? SharedConfiguration() else { return }
        let path = config.dataDirectory.appendingPathComponent("stubble.log")
        let fm = FileManager.default

        // Create parent directory if needed
        try? fm.createDirectory(at: config.dataDirectory, withIntermediateDirectories: true)

        // Rotate if the log is too large
        rotateIfNeeded(logPath: path, dataDir: config.dataDirectory, fm: fm)

        // Create or open for appending
        if !fm.fileExists(atPath: path.path) {
            fm.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // Ensure owner-only access (0600) — log may contain window titles and activity details.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        fileHandle = FileHandle(forWritingAtPath: path.path)
        fileHandle?.seekToEndOfFile()
        logPath = path
        dataDir = config.dataDirectory
        writesSinceRotationCheck = 0
    }

    /// Rotate the log file if it exceeds maxLogSize.
    private static func rotateIfNeeded(logPath: URL, dataDir: URL, fm: FileManager) {
        guard fm.fileExists(atPath: logPath.path),
              let attrs = try? fm.attributesOfItem(atPath: logPath.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize
        else { return }

        let oldPath = dataDir.appendingPathComponent("stubble.log.old")
        try? fm.removeItem(at: oldPath)
        try? fm.moveItem(at: logPath, to: oldPath)
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

            // Periodically check if log rotation is needed during long sessions
            writesSinceRotationCheck += 1
            if writesSinceRotationCheck >= rotationCheckInterval,
               let path = logPath, let dir = dataDir {
                writesSinceRotationCheck = 0
                let fm = FileManager.default
                rotateIfNeeded(logPath: path, dataDir: dir, fm: fm)
                if !fm.fileExists(atPath: path.path) {
                    // File was rotated — reopen
                    fh.closeFile()
                    fm.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    fileHandle = FileHandle(forWritingAtPath: path.path)
                    fileHandle?.seekToEndOfFile()
                }
            }
        }
        fileLock.unlock()
    }

    public static func debug(_ msg: String) { log(.debug, msg) }
    public static func info(_ msg: String) { log(.info, msg) }
    public static func warning(_ msg: String) { log(.warning, msg) }
    public static func error(_ msg: String) { log(.error, msg) }
}
