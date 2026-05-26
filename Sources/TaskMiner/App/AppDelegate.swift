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
    private let fileActivityMonitor: FileActivityMonitor
    private let calendarMonitor: CalendarMonitor
    private let granolaMeetingMonitor: GranolaMeetingMonitor
    private let windowGeometryCapture: WindowGeometryCapture
    private var mediaActivityDetector: MediaActivityDetector?
    /// Lazy-initialized so the daemon defers AI setup until first summarization.
    /// Requires signed-in user with valid subscription for proxy mode.
    private lazy var taskSummarizer: TaskSummarizer? = {
        if let geminiClient = GeminiClient.resolvedClient() {
            Logger.info("Gemini AI summarization enabled")
            return TaskSummarizer(geminiClient: geminiClient)
        } else {
            Logger.info("No AI access — AI summarization disabled (OCR still active)")
            return nil
        }
    }()

    // MARK: - Mutable State (main-thread only)
    // All callbacks (activityMonitor, windowTitleMonitor, idleDetector, timers)
    // run on CFRunLoopGetMain / DispatchQueue.main, so these properties are safe
    // to access without locks. startNewActivity/finalizeCurrentActivity assert this.

    private var currentActivity: ActivityRecord?
    private var currentActivityId: Int64?
    private var periodicTimer: Timer?
    private var summarizationTimer: Timer?
    private var lastScreenshotTime: Date = .distantPast
    private var lastSummaryDate: String = ""
    private var lastSummarizationTime: Date = .distantPast
    private var lastMemoryReviewDate: String = ""
    private var lastPruneDate: String = ""
    private var isShuttingDown = false
    private var lastLoggedMediaSuppression = false

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
        self.fileActivityMonitor = FileActivityMonitor()
        self.calendarMonitor = CalendarMonitor()
        self.granolaMeetingMonitor = GranolaMeetingMonitor()
        self.windowGeometryCapture = WindowGeometryCapture()
    }

    func start() {
        // Crash recovery: finalize any stale activities from previous crashed sessions
        db.finalizeStaleActivities()

        // Run knowledge graph migration from memory.json (one-time, on first launch after update)
        if let migrated = GraphMigration.migrateIfNeeded(memoryPath: config.shared.memoryPath, store: db) {
            Logger.info("Knowledge graph migration complete: \(migrated) nodes created")
            backfillKnowledgeGraphFromHistory()
        } else {
            // Even without migration, backfill if graph is nearly empty
            let nodeCount = db.knowledgeNodeCount()
            if nodeCount < 5 {
                Logger.info("Knowledge graph has \(nodeCount) nodes, running backfill...")
                backfillKnowledgeGraphFromHistory()
            }
        }

        // One-time cleanup of invalid nodes (short names, first names, garbage data)
        let cleanupVersion = UserDefaults.standard.integer(forKey: "graphCleanupVersion")
        if cleanupVersion < 1 {
            let cleaned = GraphMigration.cleanupInvalidNodes(store: db)
            if cleaned > 0 {
                Logger.info("Graph cleanup: removed \(cleaned) invalid nodes")
            }
            UserDefaults.standard.set(1, forKey: "graphCleanupVersion")
        }

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

        // Initialize media activity detection (video calls, streaming, calendar meetings)
        // This suppresses idle detection when the user is watching/listening
        mediaActivityDetector = MediaActivityDetector(
            activityMonitor: activityMonitor,
            calendarMonitor: calendarMonitor,
            windowTitleMonitor: windowTitleMonitor
        )
        idleDetector.isUserEngagedInMedia = { [weak self] in
            self?.mediaActivityDetector?.isUserEngagedInMedia() ?? false
        }

        // Wire up file activity callback
        fileActivityMonitor.onFileChanges = { [weak self] events in
            guard let self else { return }
            self.db.insertFileEvents(events, activityId: self.currentActivityId)
        }

        // Start monitoring
        activityMonitor.start()
        fileActivityMonitor.start()

        // Request calendar access (non-blocking, user sees permission prompt once)
        calendarMonitor.requestAccess()

        // Wire up Granola meeting monitor callback
        granolaMeetingMonitor.onMeetingsUpdated = { [weak self] meetings in
            guard let self else { return }
            for meeting in meetings {
                self.db.upsertGranolaMeeting(meeting)
            }
            Logger.info("Imported \(meetings.count) Granola meeting(s)")
        }

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
        // The actual Gemini client is lazy-initialized on first summarization (~15 min).
        lastSummarizationTime = Date()
        summarizationTimer = Timer.scheduledTimer(
            withTimeInterval: 60, // Check every 60s, run every 15 min
            repeats: true
        ) { [weak self] _ in
            self?.checkSummarization()
        }

        // Listen for knowledge graph rebuild requests from the dashboard
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("rebuildKnowledgeGraph"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Logger.info("Received knowledge graph rebuild request")
            self?.backfillKnowledgeGraphFromHistory()
        }

        Logger.info("Stubble started - monitoring desktop activity")
        Logger.info("Screenshot interval: \(Int(config.screenshotInterval))s, Idle threshold: \(Int(config.idleThreshold))s")
        Task {
            let permStatus = await PermissionManager.currentStatus()
            Logger.info("Permissions — Screen Recording: \(permStatus.screenRecording ? "✅" : "❌"), Accessibility: \(permStatus.accessibility ? "✅" : "❌")")
            if !permStatus.screenRecording {
                Logger.warning("Screen Recording permission not granted — screenshots will be skipped until granted. Re-grant in System Settings → Privacy & Security → Screen Recording.")
            }
            if !permStatus.accessibility {
                Logger.warning("Accessibility permission not granted — window titles will be empty. Re-grant in System Settings → Privacy & Security → Accessibility.")
            }
        }
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
        fileActivityMonitor.stop()

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
        guard !pauseController.isPaused else { return }

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
        guard !pauseController.isPaused else { return }
        guard let current = currentActivity else { return }

        // Only create a new activity if the title actually differs
        guard current.windowTitle != newTitle else { return }

        // Finalize current
        finalizeCurrentActivity()

        // Capture extended AX context at the moment of title change
        let ctx = windowTitleMonitor.lastContext

        // Start new with same app but new title
        let record = ActivityRecord(
            appName: current.appName,
            bundleId: current.bundleId,
            windowTitle: newTitle,
            isIdle: false,
            browserURL: ctx.browserURL,
            documentPath: ctx.documentPath,
            focusedElementRole: ctx.focusedElementRole
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
        // Log when media activity prevents idle (only when HID says idle but media is engaged)
        let hidIdle = idleDetector.idleTime >= config.idleThreshold
        if hidIdle, let reason = mediaActivityDetector?.engagementReason() {
            if !lastLoggedMediaSuppression {
                Logger.info("Idle suppressed: \(reason)")
                lastLoggedMediaSuppression = true
            }
        } else {
            lastLoggedMediaSuppression = false
        }
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

        // 4. Daily summary at midnight rollover + OCR digest + screenshot cap
        let today = todayString()
        if today != lastSummaryDate {
            // Generate summary for yesterday
            if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) {
                db.generateDailySummary(for: yesterday)
                // Build and cache the OCR digest for yesterday (before images are pruned)
                let ocrTexts = db.ocrTextsForDate(yesterday)
                if !ocrTexts.isEmpty {
                    let digest = OCRDigestBuilder.buildDigest(from: ocrTexts)
                    if let section = digest.asPromptSection() {
                        let dateStr = SharedFormatters.dayFormatter.string(from: yesterday)
                        db.insertOrReplaceOCRDigest(date: dateStr, digest: section)
                        Logger.info("Generated OCR digest for \(dateStr) from \(ocrTexts.count) screenshots")
                    }
                }
            }
            lastSummaryDate = today
            // Reset daily tracked app launches at midnight
            activityMonitor.resetLaunchedApps()
        }

        // 5. Daily memory review — run decay/pruning even on quiet days with no new entries.
        //    Also maintains the knowledge graph (decay + pruning).
        //    Triggers once per day alongside the midnight rollover.
        if lastMemoryReviewDate != today {
            lastMemoryReviewDate = today
            let memoryStore = UserMemoryStore(filePath: config.shared.memoryPath)
            memoryStore.mergeStructured(newEntries: [])  // runs decay + pruning pass
            Logger.debug("Daily memory review: decay pass completed")

            // Knowledge graph maintenance
            Task { @MainActor in
                let graph = KnowledgeGraph(store: self.db)
                let decayed = graph.applyDecay()
                let pruned = graph.prune(belowConfidence: 0.15)
                if decayed > 0 || pruned > 0 {
                    Logger.info("Knowledge graph maintenance: decayed \(decayed), pruned \(pruned)")
                }
            }
        }

        // 6. Tiered screenshot pruning (once per day):
        //    - Tier 1: delete image files beyond the latest 100 (keep OCR text in DB)
        //    - Tier 2: delete entire DB rows older than 30 days
        if lastPruneDate != today {
            lastPruneDate = today
            let prunedPaths = db.pruneScreenshotImages(keepLatest: 100)
            if !prunedPaths.isEmpty {
                screenshotStorage.cleanupFiles(relativePaths: prunedPaths)
            }
            db.deleteScreenshotsOlderThan(days: 30)
            db.deleteFileEventsOlderThan(days: 30)
            db.deleteGranolaMeetingsOlderThan(days: 90)
        }

        // Poll Granola meetings (checks file mod-date first, no-op if unchanged)
        granolaMeetingMonitor.poll()
    }

    // MARK: - Idle Transition Handling

    /// Shared handler for idle transitions from both HID polling and system events.
    private func handleIdleTransition(_ transition: IdleDetector.IdleTransition) {
        guard !pauseController.isPaused else { return }
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
        dispatchPrecondition(condition: .onQueue(.main))
        var record = ActivityRecord(
            appName: appName,
            bundleId: bundleId,
            isIdle: isIdle
        )

        // Read window title + extended AX context for non-idle activities
        if !isIdle && pid != 0 {
            windowTitleMonitor.currentBundleId = bundleId
            windowTitleMonitor.updateFocusedApp(pid: pid)
            record.windowTitle = windowTitleMonitor.title.isEmpty ? nil : windowTitleMonitor.title

            // Populate extended context from AX
            let ctx = windowTitleMonitor.lastContext
            record.browserURL = ctx.browserURL
            record.documentPath = ctx.documentPath
            record.focusedElementRole = ctx.focusedElementRole
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
        dispatchPrecondition(condition: .onQueue(.main))
        guard let activity = currentActivity, let id = currentActivityId else { return }

        let now = Date()
        let cal = Calendar.current

        // Check if activity spans midnight — if so, split at day boundary
        let activityStart = activity.timestamp
        let startOfActivityDay = cal.startOfDay(for: activityStart)
        let startOfCurrentDay = cal.startOfDay(for: now)

        if startOfActivityDay != startOfCurrentDay {
            // Activity spans midnight — finalize yesterday's portion, insert today's portion
            let midnight = startOfCurrentDay
            let yesterdayDuration = midnight.timeIntervalSince(activityStart)

            // Finalize yesterday's activity up to midnight
            do {
                try db.finalizeActivity(id: id, endTime: midnight, duration: yesterdayDuration)
                Logger.debug("Split activity \(id) at midnight: \(activity.appName) yesterday=\(Int(yesterdayDuration))s")
            } catch {
                Logger.error("Failed to finalize yesterday portion of activity \(id): \(error.localizedDescription)")
            }

            // Insert today's portion as a new activity
            let todayDuration = now.timeIntervalSince(midnight)
            if todayDuration > 1 { // Only insert if meaningful duration
                let todayActivity = ActivityRecord(
                    timestamp: midnight,
                    appName: activity.appName,
                    bundleId: activity.bundleId,
                    windowTitle: activity.windowTitle,
                    isIdle: activity.isIdle,
                    browserURL: activity.browserURL,
                    documentPath: activity.documentPath,
                    focusedElementRole: activity.focusedElementRole
                )
                do {
                    let todayId = try db.insertActivity(todayActivity)
                    try db.finalizeActivity(id: todayId, endTime: now, duration: todayDuration)
                    Logger.debug("Split activity: today portion \(todayId) = \(Int(todayDuration))s")
                } catch {
                    Logger.error("Failed to insert today portion of split activity: \(error.localizedDescription)")
                }
            }
        } else {
            // Normal case — activity within same day
            let duration = now.timeIntervalSince(activityStart)
            do {
                try db.finalizeActivity(id: id, endTime: now, duration: duration)
            } catch {
                Logger.error("Failed to finalize activity \(id): \(error.localizedDescription)")
            }
            Logger.debug("Finalized activity \(id): \(activity.appName) (\(Int(duration))s)")
        }

        currentActivity = nil
        currentActivityId = nil
    }

    // MARK: - Screenshots

    private func takeScreenshot(trigger: ScreenshotTrigger) {
        guard !isShuttingDown else { return }
        guard !pauseController.isPaused else { return }

        // Attempt the actual capture — this is the real permission test.
        // NOTE: We deliberately do NOT gate on CGPreflightScreenCaptureAccess() because
        // it caches its result for the lifetime of the process and never reflects
        // newly-granted TCC permissions. CGWindowListCreateImage checks TCC in real time,
        // so the daemon starts capturing as soon as the user grants Screen Recording.
        Logger.info("takeScreenshot(trigger: \(trigger.rawValue))")
        let now = Date()
        let path = screenshotStorage.generatePath(for: now)

        guard let image = screenshotCapture.captureFullScreen() else {
            Logger.warning("Screenshot capture returned nil — Screen Recording permission likely not granted")
            return
        }

        // Validate the captured image has real content (width & height > 0).
        guard image.width > 0 && image.height > 0 else {
            Logger.warning("Screenshot captured but has zero dimensions — skipping")
            return
        }

        let capturedActivityId = currentActivityId

        // Capture window geometry alongside screenshot (synchronous, fast)
        if let snapshot = windowGeometryCapture.captureSnapshot() {
            db.insertWindowSnapshot(snapshot, activityId: capturedActivityId)
        }

        // Update timestamp synchronously to prevent duplicate captures while
        // the background queue is still processing OCR + JPEG save.
        lastScreenshotTime = now

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard self.screenshotCapture.saveAsJPEG(image: image, to: path) else {
                Logger.error("Screenshot save failed to \(path.path)")
                return
            }
            // Restrict screenshot file to owner-only access (0600)
            self.screenshotStorage.restrictPermissions(at: path)
            var ocrText = self.ocrEngine.recognizeText(in: image)
            if let text = ocrText {
                Logger.debug("OCR extracted \(text.count) chars from screenshot")
                // Cap OCR text to prevent huge DB entries from dense screenshots
                if text.count > 50_000 {
                    ocrText = String(text.prefix(50_000))
                    Logger.debug("OCR text capped at 50k chars")
                }
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

        // Skip the expensive AI call if there's been minimal new activity since last run.
        // Threshold: at least 5 non-idle activity records since last summarization.
        // Note: do NOT advance lastSummarizationTime on skip — otherwise a slow trickle
        // of <5 activities per 15min would never trigger summarization.
        let newActivityCount = db.nonIdleActivityCount(since: lastSummarizationTime)
        guard newActivityCount >= 5 else {
            Logger.debug("Skipping summarization — only \(newActivityCount) new activities since last run")
            return
        }

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

        // Gather file events for the summarization window
        let fileEvents = db.recentFileEvents(from: startTime, to: endTime, limit: 100)

        // Gather calendar context for the day
        let calContext = calendarMonitor.eventsContext(from: startTime, to: endTime)

        // Gather Granola meeting data for the day
        let granolaMeetings = db.recentGranolaMeetings(from: startTime, to: endTime)

        // Load settings from shared settings file (reuse config.shared, no redundant init)
        let cliSettings: CLISettings? = {
            guard let data = try? Data(contentsOf: self.config.shared.settingsPath),
                  let settings = try? JSONDecoder().decode(CLISettings.self, from: data)
            else { return nil }
            return settings
        }()

        // Load memory context — prefer knowledge graph, fall back to legacy memory store
        let memoryStore = UserMemoryStore(filePath: self.config.shared.memoryPath)
        // Note: Graph context is loaded asynchronously inside the Task below

        // Compute significant idle breaks for session-aware task generation
        let minAwaySeconds = TimeInterval((cliSettings?.minAwayMinutes ?? 15) * 60)
        let significantBreaks = Self.consolidateIdleBreaks(from: activityData, minDuration: minAwaySeconds)

        // Load recent project names for consistent naming across days
        let recentProjectNames = loadRecentProjectNames(db: db, excluding: todayString(), days: 7)

        let db = self.db
        let dateStr = todayString()
        Task {
            do {
                // Load memory context — prefer knowledge graph, fall back to legacy memory store
                let memoryContext: String? = await {
                    let graph = await MainActor.run { KnowledgeGraph(store: db) }
                    if let graphContext = await graph.contextString() {
                        return graphContext
                    }
                    return memoryStore.contextString()
                }()

                let result = try await summarizer.summarize(
                    activities: activityData,
                    date: endTime,
                    customPrompt: cliSettings?.customPrompt,
                    memoryContext: memoryContext,
                    granularity: cliSettings?.granularity ?? .medium,
                    fileEvents: fileEvents,
                    calendarContext: calContext,
                    significantBreaks: significantBreaks,
                    recentProjectNames: recentProjectNames,
                    exclusions: cliSettings?.exclusions ?? ["Exclude adult, explicit, or NSFW content"],
                    granolaMeetings: granolaMeetings
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

                    // Persist project activities from the same AI response
                    if !result.projects.isEmpty {
                        Self.persistProjectClusters(result.projects, tasks: result.tasks, dateStr: dateStr, db: db)
                    }

                    // Merge new structured memory entries
                    if !result.newMemoryEntries.isEmpty {
                        memoryStore.mergeStructured(newEntries: result.newMemoryEntries)
                    }

                    // Upsert knowledge graph updates
                    if !result.graphUpdates.isEmpty {
                        let graph = KnowledgeGraph(store: db)
                        for node in result.graphUpdates.nodes {
                            graph.upsertNode(node)
                        }
                        for edge in result.graphUpdates.edges {
                            graph.upsertEdge(edge)
                        }
                        Logger.info("Graph updated: \(result.graphUpdates.nodes.count) nodes, \(result.graphUpdates.edges.count) edges")
                    }
                }

                // Re-synthesize user profile after memory changes (runs in background)
                if !result.newMemoryEntries.isEmpty {
                    let synthesizer = ProfileSynthesizer(geminiClient: summarizer.geminiClient)
                    await synthesizer.synthesizeIfNeeded(store: memoryStore)
                }
            } catch {
                await MainActor.run {
                    Logger.error("Summarization failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Load recent project names from past days for consistent naming.
    private func loadRecentProjectNames(db: DatabaseManager, excluding todayStr: String, days: Int) -> [String] {
        let cal = Calendar.current
        let today = Date()
        var names = Set<String>()
        for offset in 1...days {
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let dateStr = SharedFormatters.dayFormatter.string(from: date)
            for name in db.projectActivityNames(for: dateStr) {
                names.insert(name)
            }
        }
        return Array(names).sorted()
    }

    /// Convert ProjectClusterData into ProjectActivityRecords and persist to DB.
    private static func persistProjectClusters(_ clusters: [ProjectClusterData], tasks: [TaskRecord], dateStr: String, db: DatabaseManager) {
        do {
            try db.deleteProjectActivities(for: dateStr)
        } catch {
            Logger.error("Failed to delete old project activities: \(error.localizedDescription)")
            return
        }

        var records: [ProjectActivityRecord] = []
        var assignedIndices = Set<Int>()

        for cluster in clusters {
            let validIndices = cluster.taskIndices.filter { $0 >= 0 && $0 < tasks.count && !assignedIndices.contains($0) }
            guard !validIndices.isEmpty else { continue }
            for idx in validIndices { assignedIndices.insert(idx) }

            let clusterTasks = validIndices.map { tasks[$0] }
            let totalDuration = clusterTasks.reduce(0.0) { $0 + $1.duration }
            let startTime = clusterTasks.map(\.startTime).min() ?? clusterTasks[0].startTime
            let endTime = clusterTasks.map(\.endTime).max() ?? clusterTasks[0].endTime

            let appsJSON: String
            if !cluster.apps.isEmpty {
                appsJSON = (try? JSONSerialization.data(withJSONObject: cluster.apps)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            } else {
                var apps: [String] = []
                var seen = Set<String>()
                for task in clusterTasks {
                    for app in task.appNamesList where seen.insert(app).inserted { apps.append(app) }
                }
                appsJSON = (try? JSONSerialization.data(withJSONObject: apps)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            }

            let titlesJSON = (try? JSONSerialization.data(withJSONObject: clusterTasks.map(\.title))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            // Use djb2 hash for stable color index (same algorithm as ProjectActivity.stableColorIndex)
            var hash: UInt64 = 5381
            for byte in cluster.name.lowercased().utf8 {
                hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
            }
            let colorIndex = Int(hash % 8) // 8 = typical barPalette size

            records.append(ProjectActivityRecord(
                date: dateStr,
                name: cluster.name,
                summary: cluster.summary,
                totalDuration: totalDuration,
                appNames: appsJSON,
                taskTitles: titlesJSON,
                startTime: startTime,
                endTime: endTime,
                colorIndex: colorIndex
            ))
        }

        // Create "Other" project for unassigned tasks (matches dashboard's resolveProjectActivities)
        let unassigned = tasks.indices.filter { !assignedIndices.contains($0) }
        if !unassigned.isEmpty {
            let otherTasks = unassigned.map { tasks[$0] }
            let totalDuration = otherTasks.reduce(0.0) { $0 + $1.duration }
            let startTime = otherTasks.map(\.startTime).min() ?? otherTasks[0].startTime
            let endTime = otherTasks.map(\.endTime).max() ?? otherTasks[0].endTime

            var apps: [String] = []
            var seen = Set<String>()
            for task in otherTasks {
                for app in task.appNamesList where seen.insert(app).inserted { apps.append(app) }
            }
            let appsJSON = (try? JSONSerialization.data(withJSONObject: apps)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let titlesJSON = (try? JSONSerialization.data(withJSONObject: otherTasks.map(\.title))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            // Use same djb2 hash algorithm for "Other" color
            var hash: UInt64 = 5381
            for byte in "other".utf8 {
                hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
            }
            let colorIndex = Int(hash % 8)

            records.append(ProjectActivityRecord(
                date: dateStr,
                name: "Other",
                summary: "Miscellaneous activities.",
                totalDuration: totalDuration,
                appNames: appsJSON,
                taskTitles: titlesJSON,
                startTime: startTime,
                endTime: endTime,
                colorIndex: colorIndex
            ))
        }

        do {
            try db.insertProjectActivities(records)
            Logger.info("Persisted \(records.count) project activities")
        } catch {
            Logger.error("Failed to insert project activities: \(error.localizedDescription)")
        }
    }

    /// Minimal Codable struct to read the shared settings file from the dashboard.
    private struct CLISettings: Codable {
        var customPrompt: String?
        var granularity: TaskGranularity?
        var minAwayMinutes: Int?
        var exclusions: [String]?
    }

    /// Consolidate idle activities into merged break periods, filtering by minimum duration.
    /// Handles unfinalized idle records (no duration) by estimating end from the next non-idle activity.
    static func consolidateIdleBreaks(
        from activities: [SummarizationInput],
        minDuration: TimeInterval
    ) -> [(start: Date, end: Date)] {
        let sorted = activities.sorted { $0.timestamp < $1.timestamp }

        var idles: [(start: Date, end: Date)] = []
        for (i, activity) in sorted.enumerated() {
            guard activity.isIdle else { continue }

            let end: Date
            if let dur = activity.duration, dur > 0 {
                end = activity.timestamp.addingTimeInterval(dur)
            } else {
                // Unfinalized idle record — estimate end from the next non-idle activity
                let nextNonIdle = sorted.dropFirst(i + 1).first { !$0.isIdle }
                end = nextNonIdle?.timestamp ?? activity.timestamp
            }

            let duration = end.timeIntervalSince(activity.timestamp)
            guard duration >= minDuration else { continue }
            idles.append((start: activity.timestamp, end: end))
        }

        guard !idles.isEmpty else { return [] }

        // Merge overlapping/adjacent idle periods
        var merged: [(start: Date, end: Date)] = [idles[0]]
        for idle in idles.dropFirst() {
            if idle.start <= merged[merged.count - 1].end {
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, idle.end)
            } else {
                merged.append(idle)
            }
        }

        return merged
    }

    // MARK: - Helpers

    private func todayString() -> String {
        SharedFormatters.dayFormatter.string(from: Date())
    }

    // MARK: - Knowledge Graph Backfill

    /// Backfill the knowledge graph from existing historical data.
    /// Called once after migration to enrich the graph with tasks, projects, and browser history.
    private func backfillKnowledgeGraphFromHistory() {
        // Get last 30 days of tasks
        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -30, to: endDate) else { return }

        var allTasks: [TaskRecord] = []
        var allProjects: [ProjectActivityRecord] = []

        // Collect tasks and projects from the last 30 days
        var currentDate = startDate
        while currentDate <= endDate {
            let dateStr = SharedFormatters.dayFormatter.string(from: currentDate)
            allTasks.append(contentsOf: db.tasks(for: dateStr))
            allProjects.append(contentsOf: db.projectActivities(for: dateStr))
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? endDate
        }

        // Backfill from tasks and projects
        if !allTasks.isEmpty || !allProjects.isEmpty {
            let backfilled = GraphMigration.backfillFromHistoricalData(
                tasks: allTasks,
                projectActivities: allProjects,
                store: db
            )
            if backfilled > 0 {
                Logger.info("Knowledge graph backfilled \(backfilled) nodes from \(allTasks.count) tasks and \(allProjects.count) projects")
            }
        }

        // Backfill topics from browser history
        let activities = db.activities(
            from: startDate,
            to: endDate,
            includeIdle: false,
            limit: 5000
        )
        let activitiesWithURLs = activities.filter { $0.browserURL != nil && !$0.browserURL!.isEmpty }
        if !activitiesWithURLs.isEmpty {
            let topicsCreated = GraphMigration.extractTopicsFromBrowserHistory(
                activities: activitiesWithURLs,
                store: db
            )
            if topicsCreated > 0 {
                Logger.info("Knowledge graph: extracted \(topicsCreated) topics from \(activitiesWithURLs.count) browser activities")
            }
        }
    }
}
