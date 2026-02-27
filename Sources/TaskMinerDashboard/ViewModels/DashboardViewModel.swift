import Foundation
import SwiftUI
import UniformTypeIdentifiers
import TaskMinerShared

@Observable
@MainActor
final class DashboardViewModel {
    let config: SharedConfiguration?
    var configurationError: String?
    let dbReader: DatabaseReader?
    let pauseController: PauseController
    let taskWriter: TaskWriter?
    var taskSummarizer: TaskSummarizer?
    var geminiClient: GeminiClient?
    let memoryStore: UserMemoryStore

    var selectedDate: Date = Date()
    var availableDates: [String] = []

    // Activity data
    var activities: [ActivityRecord] = []
    var groupedActivities: [ActivityGroup] = []
    var activeSeconds: Double = 0
    var idleSeconds: Double = 0

    // Screenshots
    var screenshots: [ScreenshotRecord] = []

    // File events (filesystem monitoring)
    var fileEvents: [FileEventRecord] = []

    // Granola meetings (imported from Granola cache)
    var granolaMeetings: [GranolaMeetingRecord] = []

    // Tasks (AI-generated)
    var tasks: [TaskRecord] = []
    var isGeneratingSummary = false
    var summaryError: String?
    /// Whether a Gemini API key is configured (cosmetic — used for status indicators in Settings).
    var hasGeminiKey: Bool

    // AI day summary (generated alongside tasks)
    var daySummaryText: String?

    // Project activities (AI-clustered from tasks)
    var projectActivities: [ProjectActivity] = []
    var isGeneratingActivities = false
    var activitiesError: String?
    var activityGenerator: ProjectActivityGenerator?

    // Stubs page (AI-generated, persisted per day)
    var recommendations: [Recommendation] = []
    var greetingContext: String?
    var daySummaryContent: String?
    var suggestedQuestions: [String] = []
    var isGeneratingRecommendations = false
    var recommendationsError: String?
    var recommendationGenerator: RecommendationGenerator?
    /// Tracks whether we've already attempted to auto-generate stubs for this date,
    /// so we don't re-trigger on every tab switch.
    var hasAttemptedStubsGeneration = false

    /// Whether the user is viewing today's date (forward-looking stubs) or a past day (retrospective summary).
    var isViewingToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    // Expand state — only one item expanded at a time across the whole screen.
    // Setting one to a value automatically means the others are collapsed.
    var expandedTaskId: Int64?
    var expandedProjectActivityId: UUID?
    var expandedActivityGroupId: String?

    // Chat
    var chatMessages: [ChatMessage] = []
    var isChatLoading = false
    var chatError: String?
    /// The name of the currently active screen/tab (e.g. "Timeline", "Stubs", "Activities").
    /// Used to give the chat assistant context about what the user is looking at.
    var currentScreen: String = "Stubs"
    /// Set by the Stubs page to trigger a chat question. ChatOverlayView observes this,
    /// expands, sends the message, and clears it.
    var pendingChatQuestion: String?

    // Habits (cross-day analysis)
    var habitsAnalysis: HabitsAnalysis?
    var habitsSnapshot: HabitsDataSnapshot?
    var isGeneratingHabits = false
    var habitsError: String?
    var habitsGenerator: HabitsGenerator?
    var hasAttemptedHabitsGeneration = false

    // App name → bundle ID mapping (for icon resolution)
    var appNameBundleMap: [String: String] = [:]

    // In-flight AI task handles (for cancellation on new request)
    var recommendationsTask: Task<Void, Never>?
    var habitsTask: Task<Void, Never>?

    // Pause
    var pauseState: PauseState?
    private var pauseTimer: Timer?
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var timeChangeObserver: NSObjectProtocol?

    deinit {
        // deinit is nonisolated but this @MainActor class is always deallocated on
        // the main thread (owned by the SwiftUI view hierarchy). assumeIsolated is
        // the standard pattern for accessing @MainActor properties from deinit.
        MainActor.assumeIsolated {
            pauseTimer?.invalidate()
            refreshTimer?.invalidate()
            if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
            if let timeChangeObserver { NotificationCenter.default.removeObserver(timeChangeObserver) }
        }
    }

    init() {
        do {
            self.config = try SharedConfiguration()
            self.configurationError = nil
        } catch {
            self.config = nil
            self.configurationError = "Application Support unavailable: \(error.localizedDescription)"
        }
        let baseDir = config?.dataDirectory ?? FileManager.default.temporaryDirectory
        if let config {
            do {
                self.dbReader = try DatabaseReader(path: config.databasePath)
            } catch {
                self.dbReader = nil
                Logger.error("Failed to open database for reading: \(error.localizedDescription)")
                self.configurationError = "Database error: \(error.localizedDescription)"
            }
        } else {
            self.dbReader = nil
        }
        self.pauseController = PauseController(dataDirectory: baseDir)
        if let config {
            do {
                self.taskWriter = try TaskWriter(path: config.databasePath)
            } catch {
                self.taskWriter = nil
                Logger.error("Failed to open database for writing: \(error.localizedDescription)")
            }
        } else {
            self.taskWriter = nil
        }
        self.memoryStore = UserMemoryStore(filePath: config?.memoryPath ?? baseDir.appendingPathComponent("memory.json"))

        // Initialize AI summarization: Keychain first, then env (same as CLI).
        // Skip Keychain access if setup wizard hasn't completed yet — avoids an
        // immediate Keychain permission prompt on first launch.
        if SettingsManager.shared.hasCompletedSetup, let client = GeminiClient.resolvedClient() {
            self.geminiClient = client
            self.taskSummarizer = TaskSummarizer(geminiClient: client)
            self.activityGenerator = ProjectActivityGenerator(geminiClient: client)
            self.recommendationGenerator = RecommendationGenerator(geminiClient: client)
            self.habitsGenerator = HabitsGenerator(geminiClient: client)
            self.hasGeminiKey = true
        } else {
            self.geminiClient = nil
            self.taskSummarizer = nil
            self.activityGenerator = nil
            self.recommendationGenerator = nil
            self.habitsGenerator = nil
            self.hasGeminiKey = false
        }

        loadAvailableDates()
        loadDataForSelectedDate()
        loadChatHistory()
        loadAppNameMap()
        startPausePolling()
        startPeriodicRefresh()
        observeSystemWake()

        // Auto-generate day summaries for recent past days that don't have one yet
        autoGeneratePendingSummaries()
    }

    func selectDate(_ date: Date) {
        selectedDate = date
        daySummaryText = nil
        chatMessages = []
        chatError = nil
        isChatLoading = false
        // Reset stubs state for the new date
        recommendations = []
        greetingContext = nil
        daySummaryContent = nil
        suggestedQuestions = []
        hasAttemptedStubsGeneration = false
        recommendationsError = nil
        loadDataForSelectedDate()
        loadChatHistory()

        // Auto-generate stubs if no persisted content was loaded and we have data.
        // This handles the case where the user changes dates while already on the Stubs tab
        // (where onAppear won't re-fire).
        if recommendations.isEmpty
            && daySummaryContent == nil
            && !isGeneratingRecommendations
            && hasGeminiKey
            && !tasks.isEmpty {
            hasAttemptedStubsGeneration = true
            generateRecommendations()
        }
    }

    /// Whether the selected date is today.
    var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    // MARK: - AI Summary Generation

    func generateSummary() {
        guard let summarizer = taskSummarizer,
              let db = dbReader,
              let writer = taskWriter
        else {
            summaryError = "Gemini API key not configured (set GEMINI_API_KEY)"
            return
        }

        isGeneratingSummary = true
        summaryError = nil

        let activityData = db.activitiesWithOCR(for: selectedDate)
        guard !activityData.isEmpty else {
            isGeneratingSummary = false
            summaryError = "No activity data to summarize"
            return
        }

        let date = selectedDate
        let dateStr = SharedFormatters.dayFormatter.string(from: date)

        let memoryContext = memoryStore.contextString()
        let recentProjectNames = loadRecentProjectNames(excluding: selectedDate, days: 7)

        // Compute significant idle breaks for session-aware task generation
        let minAwaySeconds = TimeInterval(SettingsManager.shared.minAwayMinutes * 60)
        let significantBreaks = Self.consolidateIdleBreaks(from: activityData, minDuration: minAwaySeconds)

        Task {
            do {
                let result = try await summarizer.summarize(
                    activities: activityData,
                    date: date,
                    customPrompt: SettingsManager.shared.customPrompt,
                    memoryContext: memoryContext,
                    granularity: SettingsManager.shared.granularity,
                    significantBreaks: significantBreaks,
                    recentProjectNames: recentProjectNames,
                    exclusions: SettingsManager.shared.exclusions,
                    granolaMeetings: dbReader?.granolaMeetings(for: date) ?? []
                )

                try writer.deleteTasks(for: dateStr)
                try writer.insertTasks(result.tasks)

                // Persist project activities from the same AI response (no second call)
                if !result.projects.isEmpty {
                    let activities = Self.resolveProjectActivities(result.projects, tasks: result.tasks, dateStr: dateStr)
                    self.persistProjectActivities(activities, dateStr: dateStr)
                } else {
                    // Fallback: AI didn't return projects — use one-per-task
                    let fallback = ProjectActivityGenerator.fallbackActivities(from: result.tasks)
                    self.persistProjectActivities(fallback, dateStr: dateStr)
                }

                // Merge new structured memory entries and re-synthesize profile
                if !result.newMemoryEntries.isEmpty {
                    self.memoryStore.mergeStructured(newEntries: result.newMemoryEntries)
                    let profileSynth = ProfileSynthesizer(geminiClient: summarizer.geminiClient)
                    await profileSynth.synthesizeIfNeeded(store: self.memoryStore)
                }

                // Refresh all data for the day (tasks + project activities appear together)
                self.loadDataForSelectedDate()
                self.daySummaryText = result.daySummary
                self.isGeneratingSummary = false

                Analytics.summaryGenerated(taskCount: result.tasks.count)
            } catch {
                self.summaryError = error.localizedDescription
                self.isGeneratingSummary = false
                Analytics.summaryFailed()
            }
        }
    }

    /// Convert ProjectClusterData from the AI response into ProjectActivity objects
    /// using the actual task records to derive time ranges and durations.
    static func resolveProjectActivities(_ clusters: [ProjectClusterData], tasks: [TaskRecord], dateStr: String) -> [ProjectActivity] {
        let paletteSize = Theme.barPalette.count
        var assignedIndices = Set<Int>()
        var result: [ProjectActivity] = []

        for cluster in clusters {
            let validIndices = cluster.taskIndices.filter { $0 >= 0 && $0 < tasks.count && !assignedIndices.contains($0) }
            guard !validIndices.isEmpty else { continue }

            for idx in validIndices { assignedIndices.insert(idx) }

            let clusterTasks = validIndices.map { tasks[$0] }
            let totalDuration = clusterTasks.reduce(0.0) { $0 + $1.duration }
            let startTime = clusterTasks.map(\.startTime).min() ?? clusterTasks[0].startTime
            let endTime = clusterTasks.map(\.endTime).max() ?? clusterTasks[0].endTime

            // Use AI-provided apps, or fall back to extracting from tasks
            var appSet = Set<String>()
            var appList: [String] = []
            if !cluster.apps.isEmpty {
                for app in cluster.apps where appSet.insert(app).inserted { appList.append(app) }
            } else {
                for task in clusterTasks {
                    for app in task.appNamesList where appSet.insert(app).inserted { appList.append(app) }
                }
            }

            result.append(ProjectActivity(
                id: UUID(),
                name: cluster.name,
                summary: cluster.summary,
                totalDuration: totalDuration,
                appNames: appList,
                taskTitles: clusterTasks.map(\.title),
                startTime: startTime,
                endTime: endTime,
                colorIndex: ProjectActivity.stableColorIndex(for: cluster.name, paletteSize: paletteSize)
            ))
        }

        // Catch-all: unassigned tasks go into "Other"
        let unassigned = tasks.indices.filter { !assignedIndices.contains($0) }
        if !unassigned.isEmpty {
            let otherTasks = unassigned.map { tasks[$0] }
            let totalDuration = otherTasks.reduce(0.0) { $0 + $1.duration }
            var appSet = Set<String>()
            var appList: [String] = []
            for task in otherTasks {
                for app in task.appNamesList where appSet.insert(app).inserted { appList.append(app) }
            }
            result.append(ProjectActivity(
                id: UUID(),
                name: "Other",
                summary: "Miscellaneous activities.",
                totalDuration: totalDuration,
                appNames: appList,
                taskTitles: otherTasks.map(\.title),
                startTime: otherTasks.map(\.startTime).min() ?? otherTasks[0].startTime,
                endTime: otherTasks.map(\.endTime).max() ?? otherTasks[0].endTime,
                colorIndex: ProjectActivity.stableColorIndex(for: "Other", paletteSize: paletteSize)
            ))
        }

        result.sort { $0.totalDuration > $1.totalDuration }
        return result
    }

    // MARK: - Idle Break Consolidation

    /// Consolidate idle activities into merged break periods, filtering by minimum duration.
    /// Used to compute session boundaries for task generation.
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

    // MARK: - Task Editing & Deletion

    /// Update a task's title and description, then refresh from DB.
    func updateTask(id: Int64, title: String, description: String) {
        guard let writer = taskWriter else { return }
        do {
            try writer.updateTask(id: id, title: title, description: description)
            tasks = dbReader?.tasks(for: selectedDate) ?? []
            reloadProjectActivities()
        } catch {
            summaryError = "Failed to update task: \(error.localizedDescription)"
        }
    }

    /// Delete a single task by ID, then refresh from DB.
    func deleteTask(id: Int64) {
        guard let writer = taskWriter else { return }
        do {
            try writer.deleteTask(id: id)
            tasks = dbReader?.tasks(for: selectedDate) ?? []
            reloadProjectActivities()
        } catch {
            summaryError = "Failed to delete task: \(error.localizedDescription)"
        }
    }

    // MARK: - Screenshot Deletion

    /// Delete screenshots: remove files from disk, then delete DB rows, then refresh.
    func deleteScreenshots(ids: Set<Int64>) {
        guard let writer = taskWriter else { return }

        // Resolve file paths for the IDs being deleted
        let toDelete = screenshots.filter { ids.contains($0.id ?? -1) }

        // Delete files from disk first
        let fm = FileManager.default
        for record in toDelete {
            guard !record.filePath.isEmpty else { continue }
            guard let config = config else { continue }
            let fullPath = config.screenshotDirectory.appendingPathComponent(record.filePath)
            try? fm.removeItem(at: fullPath)
        }

        // Delete DB rows
        do {
            try writer.deleteScreenshots(ids: ids)
            screenshots = dbReader?.screenshots(for: selectedDate) ?? []
        } catch {
            summaryError = "Failed to delete screenshots: \(error.localizedDescription)"
        }
    }

    // MARK: - Settings

    /// Update the Gemini API key, persist it, and reinitialize the summarizer.
    func updateGeminiKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = (trimmed?.isEmpty == false) ? trimmed : nil

        SettingsManager.shared.geminiApiKey = effectiveKey

        if let apiKey = effectiveKey, let client = GeminiClient.fromAPIKey(apiKey) {
            self.geminiClient = client
            self.taskSummarizer = TaskSummarizer(geminiClient: client)
            self.activityGenerator = ProjectActivityGenerator(geminiClient: client)
            self.recommendationGenerator = RecommendationGenerator(geminiClient: client)
            self.habitsGenerator = HabitsGenerator(geminiClient: client)
            self.hasGeminiKey = true
        } else {
            self.geminiClient = nil
            self.taskSummarizer = nil
            self.activityGenerator = nil
            self.recommendationGenerator = nil
            self.habitsGenerator = nil
            self.hasGeminiKey = false
        }
    }

    // MARK: - Pause

    func pause(for duration: TimeInterval?) {
        pauseController.pause(for: duration)
        pauseState = pauseController.currentState()
        let label: String
        if let d = duration {
            label = "\(Int(d / 60))m"
        } else {
            label = "indefinite"
        }
        Analytics.monitoringPaused(duration: label)
    }

    func resumeMonitoring() {
        pauseController.resume()
        pauseState = nil
        Analytics.monitoringResumed()
    }

    // MARK: - Task ↔ Activity Color Mapping

    /// Resolves colors for the top-3 activities, ensuring no two share the same color.
    /// If a hash collision occurs, the later activity gets the next available palette slot.
    private var resolvedTop3: [(activity: ProjectActivity, color: Color)] {
        let sorted = projectActivities.sorted { $0.totalDuration > $1.totalDuration }
        let palette = Theme.barPalette
        var usedIndices = Set<Int>()
        var result: [(ProjectActivity, Color)] = []

        for activity in sorted.prefix(3) {
            var idx = activity.colorIndex % palette.count
            // If this index is already taken, find the next free one
            while usedIndices.contains(idx) {
                idx = (idx + 1) % palette.count
            }
            usedIndices.insert(idx)
            result.append((activity, palette[idx]))
        }
        return result
    }

    /// Global top-3 activities ordered by duration (stable column positions).
    var top3Activities: [(name: String, color: Color)] {
        resolvedTop3.map { ($0.activity.name, $0.color) }
    }

    /// Returns all top-3 activity colors whose time range overlaps the given task.
    func overlappingActivities(for task: TaskRecord) -> [(color: Color, name: String)] {
        resolvedTop3.compactMap { item in
            guard task.startTime < item.activity.endTime && task.endTime > item.activity.startTime else {
                return nil
            }
            return (item.color, item.activity.name)
        }
    }

    /// Scale factor to normalize project activity durations so they don't exceed active time.
    /// When the raw sum of task durations exceeds activeSeconds (due to overlapping tasks
    /// or span-time fallback), this factor brings them in line.
    var activityDurationScale: Double {
        let rawTotal = projectActivities.reduce(0.0) { $0 + $1.totalDuration }
        let activeCap = activeSeconds > 0 ? activeSeconds : rawTotal
        return rawTotal > activeCap && rawTotal > 0 ? activeCap / rawTotal : 1.0
    }

    /// Returns a set of top-3 activity names that overlap the given task.
    func overlappingActivityNames(for task: TaskRecord) -> Set<String> {
        Set(overlappingActivities(for: task).map(\.name))
    }

    // MARK: - Helpers

    /// Resolve an app display name to its bundle identifier for icon lookup.
    func bundleId(forAppName name: String) -> String? {
        appNameBundleMap[name]
    }

    // MARK: - Private

    private func loadAvailableDates() {
        availableDates = dbReader?.datesWithData() ?? []
    }

    private func loadAppNameMap() {
        appNameBundleMap = dbReader?.appNameToBundleIdMap() ?? [:]
    }

    func loadDataForSelectedDate() {
        guard let db = dbReader else { return }

        activities = db.activities(for: selectedDate)
        groupedActivities = ActivityGroup.group(activities)
        screenshots = db.screenshots(for: selectedDate)
        tasks = db.tasks(for: selectedDate)
        fileEvents = db.fileEvents(for: selectedDate)
        granolaMeetings = db.granolaMeetings(for: selectedDate)

        let summary = db.computeSummary(for: selectedDate)
        activeSeconds = summary.activeSeconds
        idleSeconds = summary.idleSeconds

        // Load persisted project activities
        let paRecords = db.projectActivities(for: selectedDate)
        projectActivities = paRecords.map { ProjectActivity(from: $0) }

        // Load persisted stubs content (if previously generated for this date)
        loadPersistedStubs(from: db)
    }

    /// Attempt to load stubs content from the database for the selected date.
    /// If found, populates greetingContext, daySummaryContent, suggestedQuestions, and recommendations.
    private func loadPersistedStubs(from db: DatabaseReader) {
        guard let record = db.stubsContent(for: selectedDate) else { return }

        greetingContext = record.greetingContext.isEmpty ? nil : record.greetingContext
        daySummaryContent = record.daySummary

        // Deserialize questions
        if let data = record.questionsJson.data(using: .utf8),
           let questions = try? JSONSerialization.jsonObject(with: data) as? [String] {
            suggestedQuestions = questions
        }

        // Deserialize recommendations
        if let data = record.recommendationsJson.data(using: .utf8),
           let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            recommendations = items.compactMap { dict -> Recommendation? in
                guard let categoryStr = dict["category"] as? String,
                      let title = dict["title"] as? String,
                      let description = dict["description"] as? String,
                      let reason = dict["reason"] as? String
                else { return nil }

                let category = Recommendation.Category(rawValue: categoryStr) ?? .bestPractice
                let actionURL = dict["action_url"] as? String
                let iconName = dict["icon"] as? String ?? category.defaultIcon

                return Recommendation(
                    id: UUID(),
                    category: category,
                    title: title,
                    description: description,
                    reason: reason,
                    actionLabel: actionURL != nil ? category.defaultActionLabel : "Noted",
                    actionURL: actionURL,
                    iconName: iconName
                )
            }
        }

        // Mark as already loaded so auto-generate doesn't fire
        if !recommendations.isEmpty || daySummaryContent != nil {
            hasAttemptedStubsGeneration = true
        }
    }

    // MARK: - Clear All Data

    /// Erase all tasks, activities, screenshots, and memory. Keeps settings (API key, etc.).
    func clearAllData() {
        // 1. Clear database tables and get screenshot paths to delete
        let screenshotPaths = dbReader?.clearAllData() ?? []

        // 2. Delete screenshot files from disk
        let fm = FileManager.default
        for path in screenshotPaths {
            try? fm.removeItem(atPath: path)
        }

        // Also clear the screenshots directory of any orphaned files
        if let config = try? SharedConfiguration() {
            let ssDir = config.screenshotDirectory
            if let files = try? fm.contentsOfDirectory(at: ssDir, includingPropertiesForKeys: nil) {
                for file in files {
                    try? fm.removeItem(at: file)
                }
            }
        }

        // 3. Reset memory
        if let config = try? SharedConfiguration() {
            try? fm.removeItem(at: config.memoryPath)
        }
        memoryStore.clear()

        // 4. Clear in-memory state
        tasks = []
        activities = []
        groupedActivities = []
        screenshots = []
        fileEvents = []
        granolaMeetings = []
        projectActivities = []
        recommendations = []
        greetingContext = nil
        daySummaryContent = nil
        suggestedQuestions = []
        chatMessages = []
        chatError = nil
        activeSeconds = 0
        idleSeconds = 0
        daySummaryText = nil
        summaryError = nil
        recommendationsError = nil
        habitsAnalysis = nil
        habitsSnapshot = nil
        habitsError = nil
        hasAttemptedHabitsGeneration = false

        Logger.info("All data cleared by user")
        Analytics.dataClearedByUser()
    }

    private func startPausePolling() {
        pauseTimer?.invalidate()
        pauseState = pauseController.currentState()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pauseState = self?.pauseController.currentState()
            }
        }
    }

    /// Listen for system wake and significant time changes (e.g. midnight rollover)
    /// so the dashboard auto-advances to today instead of showing yesterday's stale data.
    private func observeSystemWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.advanceToTodayIfNeeded() }
        }

        timeChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.advanceToTodayIfNeeded() }
        }
    }

    /// If the selected date is no longer today, auto-switch to today and reload.
    private func advanceToTodayIfNeeded() {
        guard !Calendar.current.isDateInToday(selectedDate) else {
            // Still today — just refresh data (daemon may have written new rows)
            loadAvailableDates()
            loadDataForSelectedDate()
            return
        }
        Logger.info("Dashboard: date rolled over, advancing to today")
        selectDate(Date())
    }

    /// Reload activity data from the database every 15 minutes so the dashboard
    /// stays current while the daemon writes new data in the background.
    private func startPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isViewingToday else { return }
                self.loadAvailableDates()
                self.loadDataForSelectedDate()
                Logger.debug("Periodic dashboard refresh completed")
            }
        }
    }
}
