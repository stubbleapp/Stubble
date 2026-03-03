import Foundation
import CoreServices
import TaskMinerShared

/// Monitors file system changes in user directories via FSEvents.
/// Reports batched file modification events to the daemon for inclusion
/// in the AI summarization context.
class FileActivityMonitor {
    /// Called with a batch of (path, eventType) tuples when file changes are detected.
    var onFileChanges: (([(path: String, type: String)]) -> Void)?

    private var stream: FSEventStreamRef?
    private var pendingEvents: [(path: String, type: String)] = []
    private var flushTimer: Timer?

    /// Directories to watch — user's home subdirectories likely to contain work files.
    private let watchPaths: [String]

    /// Paths to ignore — build artifacts, caches, hidden dirs, etc.
    private static let ignoredPatterns: [String] = [
        "/Library/", "/DerivedData/", "/.build/", "/node_modules/",
        "/.git/objects/", "/.git/logs/", "/.Trash/", "/Caches/",
        "/.cache/", "/__pycache__/", "/target/debug/", "/target/release/",
        "/Pods/", "/.swiftpm/", "/xcuserdata/", "/.DS_Store",
    ]

    /// File extensions to track (source code, documents, config files).
    private static let trackedExtensions: Set<String> = [
        "swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "java", "kt", "c", "cpp", "h", "m",
        "rb", "php", "sh", "zsh", "bash", "fish",
        "md", "txt", "json", "yaml", "yml", "toml", "xml", "html", "css", "scss",
        "sql", "graphql", "proto",
        "dockerfile", "makefile", "cmake",
        "xib", "storyboard", "plist",
        "csv", "tsv",
    ]

    init() {
        let home = NSHomeDirectory()
        // Watch common work directories — FSEvents is efficient even with broad paths
        watchPaths = [
            "\(home)/Documents",
            "\(home)/Projects",
            "\(home)/Developer",
            "\(home)/Desktop",
            "\(home)/Downloads",
            "\(home)/src",
            "\(home)/code",
            "\(home)/repos",
            "\(home)/work",
        ].filter { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        guard !watchPaths.isEmpty else {
            Logger.debug("FileActivityMonitor: no watched directories found")
            return
        }

        let pathsToWatch = watchPaths as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        guard let stream = FSEventStreamCreate(
            nil,
            fsEventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,  // latency: batch events every 2 seconds
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Logger.error("FileActivityMonitor: failed to create FSEventStream")
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)

        // Flush pending events every 30 seconds
        flushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.flushPendingEvents()
        }

        Logger.info("FileActivityMonitor started watching \(watchPaths.count) directories")
    }

    func stop() {
        flushTimer?.invalidate()
        flushTimer = nil
        flushPendingEvents()

        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        Logger.debug("FileActivityMonitor stopped")
    }

    // MARK: - Event Processing

    fileprivate func handleEvents(paths: [String], flags: [UInt32]) {
        for (i, path) in paths.enumerated() {
            let flag = flags[i]

            // Skip directories (we only care about file-level events)
            if flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 { continue }

            // Skip ignored paths
            if Self.ignoredPatterns.contains(where: { path.contains($0) }) { continue }

            // Only track known file extensions
            let ext = (path as NSString).pathExtension.lowercased()
            guard Self.trackedExtensions.contains(ext) || ext.isEmpty else { continue }

            // Determine event type
            let eventType: String
            if flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                eventType = "created"
            } else if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                eventType = "removed"
            } else if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
                eventType = "renamed"
            } else {
                eventType = "modified"
            }

            pendingEvents.append((path: path, type: eventType))
        }

        // Auto-flush if we have a lot of events (prevents memory buildup during heavy I/O)
        if pendingEvents.count >= 200 {
            flushPendingEvents()
        }
    }

    /// Send accumulated events to the callback, deduplicating by path.
    private func flushPendingEvents() {
        guard !pendingEvents.isEmpty else { return }

        // Deduplicate: keep only the last event per path
        var seen = Set<String>()
        var deduped: [(path: String, type: String)] = []
        for event in pendingEvents.reversed() {
            if seen.insert(event.path).inserted {
                deduped.append(event)
            }
        }
        deduped.reverse()

        Logger.debug("FileActivityMonitor: flushing \(deduped.count) file events (from \(pendingEvents.count) raw)")
        pendingEvents.removeAll()
        onFileChanges?(deduped)
    }
}

// C-level FSEvents callback
private func fsEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let monitor = Unmanaged<FileActivityMonitor>.fromOpaque(info).takeUnretainedValue()

    // eventPaths is a CFArray of CFString when using kFSEventStreamCreateFlagUseCFTypes
    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let count = CFArrayGetCount(cfArray)

    var paths: [String] = []
    var flags: [UInt32] = []
    for i in 0..<count {
        if let cfStr = CFArrayGetValueAtIndex(cfArray, i) {
            let str = Unmanaged<CFString>.fromOpaque(cfStr).takeUnretainedValue() as String
            paths.append(str)
            flags.append(eventFlags[i])
        }
    }

    DispatchQueue.main.async {
        monitor.handleEvents(paths: paths, flags: flags)
    }
}
