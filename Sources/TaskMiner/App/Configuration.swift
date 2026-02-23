import Foundation
import TaskMinerShared

struct Configuration {
    var screenshotInterval: TimeInterval = 300
    var idleThreshold: TimeInterval = 120
    var windowTitlePollInterval: TimeInterval = 2.0
    var screenshotQuality: CGFloat = 0.6
    var maxScreenshotAgeDays: Int = 7

    /// Shared paths (same as Dashboard) — single source of truth.
    let shared: SharedConfiguration

    var dataDirectory: URL { shared.dataDirectory }
    var databasePath: URL { shared.databasePath }
    var screenshotDirectory: URL { shared.screenshotDirectory }

    init() throws {
        self.shared = try SharedConfiguration()
    }

    mutating func parseArguments() {
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--screenshot-interval":
                i += 1
                if i < args.count, let val = TimeInterval(args[i]) {
                    screenshotInterval = val
                }
            case "--idle-threshold":
                i += 1
                if i < args.count, let val = TimeInterval(args[i]) {
                    idleThreshold = val
                }
            case "--screenshot-quality":
                i += 1
                if i < args.count, let val = Double(args[i]) {
                    screenshotQuality = CGFloat(val)
                }
            case "--debug":
                Logger.minimumLevel = .debug
            case "--help":
                Configuration.printUsage()
                exit(0)
            default:
                Logger.warning("Unknown argument: \(args[i])")
            }
            i += 1
        }
    }

    func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: screenshotDirectory, withIntermediateDirectories: true)
    }

    static func printUsage() {
        let usage = """
        Stubble - macOS Desktop Activity Monitor

        Usage: Stubble [options]

        Options:
          --screenshot-interval <seconds>  Screenshot interval (default: 300)
          --idle-threshold <seconds>        Idle threshold (default: 120)
          --screenshot-quality <0.0-1.0>    JPEG quality (default: 0.6)
          --debug                           Enable debug logging
          --help                            Show this help
        """
        fputs(usage + "\n", stderr)
    }
}
