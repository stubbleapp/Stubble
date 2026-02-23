import Foundation
import AppKit
import TaskMinerShared

class AppDelegate {
    private let config: Configuration
    private let db: DatabaseManager
    private let pauseController: PauseController
    private let activityMonitor: ActivityMonitor
    private let windowTitleMonitor: WindowTitleMonitor
    private let idleDetector: IdleDetector
    private let screenshotCapture: ScreenshotCapture
    private let screenshotStorage: ScreenshotStorage
    private let ocrEngine: OCREngine
    /// Lazy-initialized so the daemon doesn't hit the Keychain on startup.
    /// The Dashboard prompts for Keychain access first; by the time the daemon
    /// needs it (15 min later for the first summarization), the user has already
    /// approved once and macOS remembers the decision.
    private lazy var taskSummarizer: TaskSummarizer? = {
        if let geminiClient = GeminiClient.resolvedClient() {
            Logger.info("Gemini AI summarization enabled")
            return TaskSummarizer(geminiClient: geminiClient)
        } else {
            Logger.info("No Gemini API key — AI summarization disabled (OCR still active)")
            return nil
        }
    }()

    private var currentActivity: ActivityRecord?
    private var currentActivityId: Int64?
    private var periodicTimer: Timer?
    private var summarizationTimer: Timer?
    private var lastScreenshotTime: Date = .distantPast
    private var lastSummaryDate: String = ""
    private var lastSummarizationTime: Date = .distantPast
    private var isShuttingDown = false

    init(config: Configuration, db: DatabaseManager) throws {
        self.config = config
        self.db = db
        self.pauseController = PauseController(dataDirectory: config.dataDirectory)
        self.activityMonitor = ActivityMonitor()
        self.windowTitleMonitor = WindowTitleMonitor()
        self.idleDetector = IdleDetector(threshold: config.idleThreshold)
        self.screenshotCapture = ScreenshotCapture(quality: config.screenshotQuality)
        self.screenshotStorage = try ScreenshotStorage(
            directory: config.screenshotDirectory,
            maxAgeDays: config.maxScreenshotAgeDays
        )
        self.ocrEngine = OCREngine()
    }

    func start() {
        // Wire up app change callback
        activityMonitor.onAppChanged = { [weak self] app in
            self?.handleAppChange(app: app)
        }

        // Wire up title change callback
        windowTitleMonitor.onTitleChanged = { [weak self] title in
            self?.handleTitleChange(newTitle: title)
        }

        // Start system event observers for instant AFK detection
        // (screen lock, sleep, session switch, screensaver)
        idleDetector.startSystemEventObservers()
        idleDetector.onSystemIdleTransition = { [weak self] transition in
            self?.handleIdleTransition(transition)
        }

        // Start monitoring
        activityMonitor.start()

        // Bootstrap with current frontmost app
        if let frontApp = activityMonitor.currentApp() {
            startNewActivity(
                appName: frontApp.localizedName ?? "Unknown",
                bundleId: frontApp.bundleIdentifier,
                pid: frontApp.processIdentifier,
                isIdle: false
            )
            takeScreenshot(trigger: .manual)
        }

        // Start periodic timer on the main run loop
        periodicTimer = Timer.scheduledTimer(
            withTimeInterval: config.windowTitlePollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.periodicCheck()
        }

        // Track today's date for daily summary generation
        lastSummaryDate = todayString()

        // Start the summarization check timer unconditionally.
        // The actual Gemini client (and Keychain access) is deferred until
        // the first summarization runs (~15 min), avoiding a Keychain prompt
        // at launch that would duplicate the Dashboard's prompt.
        lastSummarizationTime = Date()
        summarizationTimer = Timer.scheduledTimer(
            withTimeInterval: 60, // Check every 60s, run every 15 min
            repeats: true
        ) { [weak self] _ in
            self?.checkSummarization()
        }

        Logger.info("Stubble started - monitoring desktop activity")
        Logger.info("Screenshot interval: \(Int(config.screenshotInterval))s, Idle threshold: \(Int(config.idleThreshold))s")
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        Logger.info("Shutting down...")

        // Stop timers
        periodicTimer?.invalidate()
        periodicTimer = nil
        summarizationTimer?.invalidate()
        summarizationTimer = nil

        // Stop monitors
        activityMonitor.stop()
        windowTitleMonitor.stop()
        idleDetector.stopSystemEventObservers()

        // Finalize current activity
        finalizeCurrentActivity()

        // Generate daily summary
        db.generateDailySummary(for: Date())

        // Close database
        db.close()

        Logger.info("Stubble stopped gracefully")
    }

    // MARK: - Event Handlers

    /// Bundle IDs of system apps that indicate the screen is locked or the user is away.
    /// These should never be recorded as real user activity.
    private static let systemIdleBundleIds: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.UserNotificationCenter",
        "com.apple.screencaptureui",
    ]

    private func handleAppChange(app: NSRunningApplication) {
        let appName = app.localizedName ?? "Unknown"
        let bundleId = app.bundleIdentifier

        // If the frontmost app is the login window, screensaver, etc., treat as idle.
        // This catches the case where the lock screen activates before (or without)
        // the screenIsLocked notification, preventing a long false activity.
        if let bid = bundleId, Self.systemIdleBundleIds.contains(bid) {
            if currentActivity?.isIdle != true {
                finalizeCurrentActivity()
                startNewActivity(appName: "Idle", bundleId: nil, pid: 0, isIdle: true)
                Logger.info("System app '\(appName)' activated — treating as idle")
            }
            return
        }

        // Skip if currently idle (e.g. screen locked) — the becameActive handler
        // will pick up the correct frontmost app when the user returns.
        if idleDetector.isIdle { return }

        // Finalize previous activity
        finalizeCurrentActivity()

        // Start new activity
        startNewActivity(
            appName: appName,
            bundleId: bundleId,
            pid: app.processIdentifier,
            isIdle: false
        )

        // Screenshot on app switch
        takeScreenshot(trigger: .appSwitch)
    }

    private func handleTitleChange(newTitle: String) {
        guard let current = currentActivity else { return }

        // Only create a new activity if the title actually differs
        guard current.windowTitle != newTitle else { return }

        // Finalize current
        finalizeCurrentActivity()

        // Start new with same app but new title
        let record = ActivityRecord(
            appName: current.appName,
            bundleId: current.bundleId,
            windowTitle: newTitle,
            isIdle: false
        )
        currentActivity = record
        do {
            currentActivityId = try db.insertActivity(record)
        } catch {
            Logger.error("Failed to insert activity: \(error.localizedDescription)")
            currentActivityId = nil
        }

        Logger.debug("New activity: \(current.appName) — \(newTitle)")

        // Screenshot on title change
        takeScreenshot(trigger: .titleChange)
    }

    // MARK: - Periodic Check

    private func periodicCheck() {
        guard !isShuttingDown else { return }
        // 0. Check pause state
        if pauseController.isPaused {
            if currentActivity != nil && currentActivity?.appName != "Paused" {
                finalizeCurrentActivity()
                startNewActivity(appName: "Paused", bundleId: nil, pid: 0, isIdle: true)
                Logger.info("Monitoring paused")
            }
            return
        } else if currentActivity?.appName == "Paused" {
            Logger.info("Monitoring resumed")
            finalizeCurrentActivity()
            if let frontApp = activityMonitor.currentApp() {
                startNewActivity(
                    appName: frontApp.localizedName ?? "Unknown",
                    bundleId: frontApp.bundleIdentifier,
                    pid: frontApp.processIdentifier,
                    isIdle: false
                )
                takeScreenshot(trigger: .appSwitch)
            }
        }

        // 1. Check idle transitions (HID-based polling)
        let transition = idleDetector.checkTransition()
        handleIdleTransition(transition)

        // 2. Poll window title (catches missed AX notifications)
        if !idleDetector.isIdle {
            windowTitleMonitor.pollTitle()
        }

        // 3. Periodic screenshot (only when active)
        if !idleDetector.isIdle {
            let elapsed = Date().timeIntervalSince(lastScreenshotTime)
            if elapsed >= config.screenshotInterval {
                takeScreenshot(trigger: .periodic)
            }
        }

        // 4. Daily summary at midnight rollover
        let today = todayString()
        if today != lastSummaryDate {
            // Generate summary for yesterday
            if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) {
                db.generateDailySummary(for: yesterday)
            }
            // Keep only current day: delete screenshot DB rows and files from previous days
            let startOfToday = Calendar.current.startOfDay(for: Date())
            db.deleteScreenshots(before: startOfToday)
            screenshotStorage.cleanupKeepingOnlyToday()
            lastSummaryDate = today
        }
    }

    // MARK: - Idle Transition Handling

    /// Shared handler for idle transitions from both HID polling and system events.
    private func handleIdleTransition(_ transition: IdleDetector.IdleTransition) {
        switch transition {
        case .becameIdle:
            Logger.info("User became idle (\(Int(idleDetector.idleTime))s)")
            finalizeCurrentActivity()
            startNewActivity(appName: "Idle", bundleId: nil, pid: 0, isIdle: true)

        case .becameActive:
            Logger.info("User became active")
            finalizeCurrentActivity()
            // Re-read current frontmost app — but skip system idle apps
            // (loginwindow may be briefly frontmost during unlock animation)
            if let frontApp = activityMonitor.currentApp(),
               !(frontApp.bundleIdentifier.map { Self.systemIdleBundleIds.contains($0) } ?? false) {
                startNewActivity(
                    appName: frontApp.localizedName ?? "Unknown",
                    bundleId: frontApp.bundleIdentifier,
                    pid: frontApp.processIdentifier,
                    isIdle: false
                )
                takeScreenshot(trigger: .appSwitch)
            }

        case .noChange:
            break
        }
    }

    // MARK: - Activity Lifecycle

    private func startNewActivity(appName: String, bundleId: String?, pid: pid_t, isIdle: Bool) {
        var record = ActivityRecord(
            appName: appName,
            bundleId: bundleId,
            isIdle: isIdle
        )

        // Read window title for non-idle activities
        if !isIdle && pid != 0 {
            windowTitleMonitor.updateFocusedApp(pid: pid)
            record.windowTitle = windowTitleMonitor.title.isEmpty ? nil : windowTitleMonitor.title
        }

        currentActivity = record
        do {
            currentActivityId = try db.insertActivity(record)
        } catch {
            Logger.error("Failed to insert activity: \(error.localizedDescription)")
            currentActivityId = nil
        }

        if !isIdle {
            Logger.info("Activity: \(appName) — \(record.windowTitle ?? "(no title)")")
        }
    }

    private func finalizeCurrentActivity() {
        guard let activity = currentActivity, let id = currentActivityId else { return }

        let now = Date()
        let duration = now.timeIntervalSince(activity.timestamp)
        do {
            try db.finalizeActivity(id: id, endTime: now, duration: duration)
        } catch {
            Logger.error("Failed to finalize activity \(id): \(error.localizedDescription)")
        }

        Logger.debug("Finalized activity \(id): \(activity.appName) (\(Int(duration))s)")

        currentActivity = nil
        currentActivityId = nil
    }

    // MARK: - Screenshots

    private func takeScreenshot(trigger: ScreenshotTrigger) {
        guard !isShuttingDown else { return }
        Logger.debug("takeScreenshot(trigger: \(trigger.rawValue))")
        let now = Date()
        let path = screenshotStorage.generatePath(for: now)

        guard let image = screenshotCapture.captureFullScreen() else {
            Logger.error("Screenshot capture failed (check Screen Recording permission)")
            return
        }

        let capturedActivityId = currentActivityId

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard self.screenshotCapture.saveAsJPEG(image: image, to: path) else {
                Logger.error("Screenshot save failed to \(path.path)")
                return
            }
            let ocrText = self.ocrEngine.recognizeText(in: image)
            if let text = ocrText {
                Logger.debug("OCR extracted \(text.count) chars from screenshot")
            }
            let record = ScreenshotRecord(
                timestamp: now,
                filePath: self.screenshotStorage.relativePath(for: path),
                fileSize: self.screenshotStorage.fileSize(at: path),
                activityId: capturedActivityId,
                trigger: trigger,
                ocrText: ocrText
            )
            DispatchQueue.main.async {
                do {
                    try self.db.insertScreenshot(record)
                    Logger.debug("Screenshot recorded (trigger: \(trigger.rawValue))")
                } catch {
                    Logger.error("Failed to insert screenshot: \(error.localizedDescription)")
                }
                self.lastScreenshotTime = now
            }
        }
    }

    // MARK: - AI Summarization

    private func checkSummarization() {
        guard !isShuttingDown else { return }
        let elapsed = Date().timeIntervalSince(lastSummarizationTime)
        guard elapsed >= 900 else { return } // 900s = 15 min
        guard !idleDetector.isIdle else { return }
        guard !pauseController.isPaused else { return }

        lastSummarizationTime = Date()
        // Summarize the full day each time — the AI sees all activity and produces
        // a coherent set of tasks. Previous tasks are deleted and replaced.
        let startOfToday = Calendar.current.startOfDay(for: Date())
        runSummarization(from: startOfToday, to: Date())
    }

    private func runSummarization(from startTime: Date, to endTime: Date) {
        guard let summarizer = taskSummarizer else { return }

        Logger.info("Running AI summarization for today's activity...")

        // Gather recent activities + OCR text from DB
        let activityData = db.recentActivitiesWithOCR(from: startTime, to: endTime)
        guard !activityData.isEmpty else {
            Logger.debug("No activities to summarize")
            return
        }

        // Load settings from shared settings file
        let cliSettings: CLISettings? = {
            guard let config = try? SharedConfiguration(),
                  let data = try? Data(contentsOf: config.settingsPath),
                  let settings = try? JSONDecoder().decode(CLISettings.self, from: data)
            else { return nil }
            return settings
        }()

        // Load memory context
        let memoryStore: UserMemoryStore? = {
            guard let config = try? SharedConfiguration() else { return nil }
            return UserMemoryStore(filePath: config.memoryPath)
        }()
        let memoryContext = memoryStore?.contextString()

        let db = self.db
        let dateStr = todayString()
        Task {
            do {
                let result = try await summarizer.summarize(
                    activities: activityData,
                    date: endTime,
                    customPrompt: cliSettings?.customPrompt,
                    memoryContext: memoryContext,
                    granularity: cliSettings?.granularity ?? .medium
                )
                guard !result.tasks.isEmpty else { return }
                await MainActor.run {
                    // Delete existing tasks for today before inserting fresh ones
                    do {
                        try db.deleteTasks(for: dateStr)
                    } catch {
                        Logger.error("Failed to delete old tasks: \(error.localizedDescription)")
                    }

                    var inserted = 0
                    for task in result.tasks {
                        do {
                            _ = try db.insertTask(task)
                            inserted += 1
                        } catch {
                            Logger.error("Failed to insert task: \(error.localizedDescription)")
                        }
                    }
                    if inserted > 0 {
                        Logger.info("AI generated \(inserted) task(s)")
                    }

                    // Merge new memory entries
                    if !result.newMemoryEntries.isEmpty {
                        memoryStore?.merge(newEntries: result.newMemoryEntries)
                    }
                }
            } catch {
                await MainActor.run {
                    Logger.error("Summarization failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Minimal Codable struct to read the shared settings file from the dashboard.
    private struct CLISettings: Codable {
        var customPrompt: String?
        var granularity: TaskGranularity?
    }

    // MARK: - Helpers

    private func todayString() -> String {
        SharedFormatters.dayFormatter.string(from: Date())
    }
}
