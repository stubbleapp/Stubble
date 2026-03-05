import Foundation
import SwiftUI
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

    // Activity data (lazy-loaded for Log view)
    var activities: [ActivityRecord] = []
    var groupedActivities: [ActivityGroup] = []
    private var activitiesLoaded = false

    // Idle activities only (for timeline gap detection - much smaller subset)
    private var idleActivitiesForTimeline: [ActivityRecord] = []

    var activeSeconds: Double = 0
    var idleSeconds: Double = 0

    // Screenshots (lazy-loaded for Log view only)
    var screenshots: [ScreenshotRecord] = []
    private var screenshotsLoaded = false

    // File events (lazy-loaded for Log view only)
    var fileEvents: [FileEventRecord] = []
    private var fileEventsLoaded = false

    // Granola meetings (imported from Granola cache)
    var granolaMeetings: [GranolaMeetingRecord] = []

    // Tasks (AI-generated)
    var tasks: [TaskRecord] = []
    var isGeneratingSummary = false
    var summaryError: String?

    // Cached timeline items (tasks + gaps) — rebuilt when tasks/activities change
    var timelineItems: [TimelineItem] = []
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
    var isGeneratingSuggestedQuestions = false
    var recommendationsError: String?
    var recommendationGenerator: RecommendationGenerator?
    /// Tracks whether we've already attempted to auto-generate stubs for this date,
    /// so we don't re-trigger on every tab switch.
    var hasAttemptedStubsGeneration = false

    /// Fingerprint of the task data when stubs were last generated.
    /// Format: "count|latestEndTimeISO" — detects when new daemon data warrants a refresh.
    var lastStubsTaskFingerprint: String = ""

    /// Timestamp of last stubs generation (or load from DB). Enforces minimum interval.
    var lastStubsGenerationTime: Date = .distantPast

    /// Minimum interval between automatic stubs refreshes (30 minutes).
    static let minStubsRefreshInterval: TimeInterval = 1800

    /// Lightweight fingerprint of the current task data.
    /// Changes when tasks are added, removed, or their time ranges shift.
    var currentTaskFingerprint: String {
        guard !tasks.isEmpty else { return "0|" }
        let latestEnd = tasks.map(\.endTime).max() ?? Date.distantPast
        return "\(tasks.count)|\(SharedFormatters.iso8601.string(from: latestEnd))"
    }

    /// Whether the user is viewing today's date (forward-looking stubs) or a past day (retrospective summary).
    var isViewingToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    /// Whether debug mode is active (Option key held). Set by ContentView.
    var isDebugMode: Bool = false

    // MARK: - Day Wrap Metrics

    /// Whether to show the Day Wrap card instead of the regular summary.
    /// True for past days, or today after the configured wrap hour (default 6pm).
    var shouldShowDayWrap: Bool {
        if !isViewingToday { return true }
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= SettingsManager.shared.dayWrapHour
    }

    /// Total focus time (non-idle task duration).
    var totalFocusTime: TimeInterval {
        tasks.reduce(0) { $0 + $1.duration }
    }

    /// Total meeting time from Granola meetings for the selected date.
    var totalMeetingTime: TimeInterval {
        granolaMeetings.reduce(0) { $0 + $1.duration }
    }

    /// Top apps by duration for the selected date.
    var topAppsByDuration: [(app: String, duration: TimeInterval, bundleId: String?)] {
        var appDurations: [String: TimeInterval] = [:]

        for task in tasks {
            for appName in task.appNamesList {
                let existing = appDurations[appName] ?? 0
                appDurations[appName] = existing + task.duration / Double(task.appNamesList.count)
            }
        }

        return appDurations
            .map { (app: $0.key, duration: $0.value, bundleId: appNameBundleMap[$0.key]) }
            .sorted { $0.duration > $1.duration }
    }

    // MARK: - Persisted Day Wrap Metrics

    /// Persisted focus time from database (for past days).
    var persistedFocusTime: TimeInterval?

    /// Persisted meeting time from database (for past days).
    var persistedMeetingTime: TimeInterval?

    /// Persisted project count from database (for past days).
    var persistedProjectCount: Int?

    /// Display focus time: live for today, persisted for past days.
    var displayFocusTime: TimeInterval {
        if isViewingToday { return totalFocusTime }
        return persistedFocusTime ?? totalFocusTime
    }

    /// Display meeting time: live for today, persisted for past days.
    var displayMeetingTime: TimeInterval {
        if isViewingToday { return totalMeetingTime }
        return persistedMeetingTime ?? totalMeetingTime
    }

    /// Display project count: live for today, persisted for past days.
    var displayProjectCount: Int {
        if isViewingToday { return projectActivities.count }
        return persistedProjectCount ?? projectActivities.count
    }

    // Expand state — only one item expanded at a time across the whole screen.
    // Setting one to a value automatically means the others are collapsed.
    var expandedTaskId: Int64?
    var expandedProjectActivityId: UUID?
    var expandedActivityGroupId: String?

    // MARK: - Projects (cross-day aggregation)

    /// Aggregated projects for the current time period.
    var aggregatedProjects: [AggregatedProject] = []

    /// Current time period for project aggregation.
    var projectsTimePeriod: ProjectTimePeriod = .week

    /// Whether projects are currently loading.
    var isLoadingProjects = false

    /// Error message for projects loading.
    var projectsError: String?

    /// Whether AI analysis is being generated for a project.
    var isGeneratingProjectAnalysis = false

    /// Cache of AI-generated project analyses (keyed by project ID).
    var projectAnalysisCache: [UUID: ProjectAnalysis] = [:]

    /// Cache of synthesized project summaries (keyed by project ID).
    /// These describe WHAT the project IS, not just what was done recently.
    var synthesizedProjectSummaries: [UUID: String] = [:]

    // MARK: - Sub-ViewModels (Domain-Specific State)

    /// Chat state and operations. Access via `chat` property.
    private(set) var chatVM: ChatViewModel!

    // MARK: - Chat (bridged to chatVM for backwards compatibility)

    var chatThreads: [ChatThread] {
        get { chatVM.threads }
        set { chatVM.threads = newValue }
    }
    var activeThreadId: Int64? {
        get { chatVM.activeThreadId }
        set { chatVM.activeThreadId = newValue }
    }
    var chatMessages: [ChatMessage] {
        get { chatVM.messages }
        set { chatVM.messages = newValue }
    }
    var isChatLoading: Bool {
        get { chatVM.isLoading }
        set { chatVM.isLoading = newValue }
    }
    var chatError: String? {
        get { chatVM.error }
        set { chatVM.error = newValue }
    }
    var isCreatingThread: Bool {
        get { chatVM.isCreatingThread }
        set { chatVM.isCreatingThread = newValue }
    }
    var isSummarizingThread: Bool {
        get { chatVM.isSummarizingThread }
        set { chatVM.isSummarizingThread = newValue }
    }
    var threadSummaryMessageCounts: [Int64: Int] {
        get { chatVM.threadSummaryMessageCounts }
        set { chatVM.threadSummaryMessageCounts = newValue }
    }
    /// The name of the currently active screen/tab (e.g. "Day", "Chat").
    /// Used to give the chat assistant context about what the user is looking at.
    var currentScreen: String = "Chat"
    /// Set by ChatTabView or ChatOverlayView to trigger a chat question.
    var pendingChatQuestion: String? {
        get { chatVM.pendingQuestion }
        set { chatVM.pendingQuestion = newValue }
    }
    /// Set to true to expand the chat overlay panel (e.g., when clicking a recent chat).
    var shouldExpandChatPanel: Bool {
        get { chatVM.shouldExpandPanel }
        set { chatVM.shouldExpandPanel = newValue }
    }

    // App name → bundle ID mapping (for icon resolution)
    var appNameBundleMap: [String: String] = [:]

    // In-flight AI task handles (for cancellation on new request)
    var recommendationsTask: Task<Void, Never>?

    // Pause
    var pauseState: PauseState?
    private var pauseTimer: Timer?
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var timeChangeObserver: NSObjectProtocol?
    private var menuBarChatObserver: NSObjectProtocol?

    deinit {
        // deinit is nonisolated but this @MainActor class is always deallocated on
        // the main thread (owned by the SwiftUI view hierarchy). assumeIsolated is
        // the standard pattern for accessing @MainActor properties from deinit.
        MainActor.assumeIsolated {
            pauseTimer?.invalidate()
            refreshTimer?.invalidate()
            if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
            if let timeChangeObserver { NotificationCenter.default.removeObserver(timeChangeObserver) }
            if let menuBarChatObserver { NotificationCenter.default.removeObserver(menuBarChatObserver) }
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

        // Initialize AI client: proxy mode (signed-in) → BYOK key (settings.json) → env var.
        // Skip if setup wizard hasn't completed yet.
        if SettingsManager.shared.hasCompletedSetup, let client = GeminiClient.resolvedClient() {
            self.geminiClient = client
            self.taskSummarizer = TaskSummarizer(geminiClient: client)
            self.activityGenerator = ProjectActivityGenerator(geminiClient: client)
            self.recommendationGenerator = RecommendationGenerator(geminiClient: client)
            self.hasGeminiKey = true
        } else {
            self.geminiClient = nil
            self.taskSummarizer = nil
            self.activityGenerator = nil
            self.recommendationGenerator = nil
            self.hasGeminiKey = false
        }

        // Initialize sub-view-models (must be done before loading data)
        // Note: We pass `self` after stored properties are initialized
        self.chatVM = ChatViewModel(
            dashboardViewModel: self,
            dbReader: dbReader,
            taskWriter: taskWriter,
            memoryStore: memoryStore,
            geminiClient: geminiClient
        )

        loadAvailableDates()
        loadDataForSelectedDate()
        loadChatThreads()
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
        // Reset stubs state for the new date
        recommendations = []
        greetingContext = nil
        daySummaryContent = nil
        suggestedQuestions = []
        hasAttemptedStubsGeneration = false
        lastStubsTaskFingerprint = ""
        lastStubsGenerationTime = .distantPast
        recommendationsError = nil
        // Reset persisted day wrap metrics
        persistedFocusTime = nil
        persistedMeetingTime = nil
        persistedProjectCount = nil

        loadDataForSelectedDate()

        // Auto-generate stubs if no persisted content was loaded and we have data.
        // This handles the case where the user changes dates while already on the Stubs tab
        // (where onAppear won't re-fire).
        // For past days: also regenerate if day summary is missing (even if recommendations exist,
        // since the record may have been created when this day was "today" with no day summary).
        let needsDaySummaryForPastDay = !isViewingToday && daySummaryContent == nil
        if (recommendations.isEmpty || needsDaySummaryForPastDay)
            && daySummaryContent == nil
            && !isGeneratingRecommendations
            && hasGeminiKey
            && !tasks.isEmpty {
            hasAttemptedStubsGeneration = true
            generateRecommendations()
        }
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
                self.summaryError = Self.friendlySummaryError(error)
                self.isGeneratingSummary = false
                Analytics.summaryFailed()
            }
        }
    }

    /// Convert errors into user-friendly messages for summary generation.
    private static func friendlySummaryError(_ error: Error) -> String {
        if let gemini = error as? GeminiError {
            switch gemini {
            case .trialExpired:
                return "Your free trial has ended. Open Settings → Account to upgrade to Pro."
            case .sessionExpired:
                return "Your session has expired. Open Settings → Account to sign in again."
            case .rateLimited:
                return "You've reached today's request limit. Upgrade to Pro for more requests."
            default:
                return gemini.localizedDescription
            }
        }
        // Use friendly message for network errors (URLError)
        return GeminiError.friendlyNetworkError(error)
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
            rebuildTimelineItems()
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
            rebuildTimelineItems()
            reloadProjectActivities()
        } catch {
            summaryError = "Failed to delete task: \(error.localizedDescription)"
        }
    }

    /// Create an initial "Getting Started with Stubble" task so the timeline isn't empty on first launch.
    func createOnboardingTask() {
        guard let writer = taskWriter else { return }

        let now = Date()
        let startTime = now.addingTimeInterval(-120) // 2 minutes ago
        let dateStr = SharedFormatters.dayFormatter.string(from: now)

        let task = TaskRecord(
            date: dateStr,
            startTime: startTime,
            endTime: now,
            title: "Getting started with Stubble",
            description: "Completed the Stubble setup wizard. Stubble is now monitoring your activity and will generate personalised insights throughout the day.",
            appNames: "[\"Stubble\"]",
            confidence: 1.0,
            relevantLinks: "[]",
            activeDuration: 120,
            websites: "[]"
        )

        do {
            try writer.insertTask(task)
            Logger.info("Created onboarding task for first launch")
        } catch {
            Logger.error("Failed to create onboarding task: \(error.localizedDescription)")
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

    /// Reinitialize all AI clients based on current auth state.
    /// Called when auth state changes (sign in, sign out, token refresh).
    func refreshForAuthChange() {
        if let client = GeminiClient.resolvedClient() {
            self.geminiClient = client
            self.taskSummarizer = TaskSummarizer(geminiClient: client)
            self.activityGenerator = ProjectActivityGenerator(geminiClient: client)
            self.recommendationGenerator = RecommendationGenerator(geminiClient: client)
            self.hasGeminiKey = true
            // Update sub-view-models
            self.chatVM.geminiClient = client
        } else {
            self.geminiClient = nil
            self.taskSummarizer = nil
            self.activityGenerator = nil
            self.recommendationGenerator = nil
            self.hasGeminiKey = false
            // Clear sub-view-models
            self.chatVM.geminiClient = nil
        }
    }

    /// Update the Gemini API key, persist it, and reinitialize the summarizer.
    /// Falls back to proxy mode if BYOK key is empty but user is signed in.
    func updateGeminiKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = (trimmed?.isEmpty == false) ? trimmed : nil

        SettingsManager.shared.geminiApiKey = effectiveKey

        if let apiKey = effectiveKey, let client = GeminiClient.fromAPIKey(apiKey) {
            self.geminiClient = client
            self.taskSummarizer = TaskSummarizer(geminiClient: client)
            self.activityGenerator = ProjectActivityGenerator(geminiClient: client)
            self.recommendationGenerator = RecommendationGenerator(geminiClient: client)
            self.hasGeminiKey = true
            // Update sub-view-models
            self.chatVM.geminiClient = client
        } else {
            // No BYOK key — try proxy mode (signed-in user) before giving up
            refreshForAuthChange()
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

    /// Returns the resolved color for a given activity.
    /// If the activity is in the top 3, returns its collision-resolved color.
    /// Otherwise, returns the raw color from its colorIndex.
    func resolvedColor(for activity: ProjectActivity) -> Color {
        // Check if this activity is in the resolved top 3
        if let match = resolvedTop3.first(where: { $0.activity.id == activity.id }) {
            return match.color
        }
        // Fallback to raw color for activities outside top 3
        return Theme.barPalette[activity.colorIndex % Theme.barPalette.count]
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

        // Load only idle activities for timeline (much smaller subset than full activities)
        idleActivitiesForTimeline = db.idleActivities(for: selectedDate)

        // Full activities, screenshots, and fileEvents are lazy-loaded only when Log view is accessed
        activities = []
        groupedActivities = []
        activitiesLoaded = false
        screenshots = []
        screenshotsLoaded = false
        fileEvents = []
        fileEventsLoaded = false

        tasks = db.tasks(for: selectedDate)
        granolaMeetings = db.granolaMeetings(for: selectedDate)

        let summary = db.computeSummary(for: selectedDate)
        activeSeconds = summary.activeSeconds
        idleSeconds = summary.idleSeconds

        // Load persisted project activities
        let paRecords = db.projectActivities(for: selectedDate)
        projectActivities = paRecords.map { ProjectActivity(from: $0) }

        // Load persisted stubs content (if previously generated for this date)
        loadPersistedStubs(from: db)

        // Rebuild cached timeline items
        rebuildTimelineItems()
    }

    /// Rebuild the cached timeline items from current tasks and activities.
    /// Call this after tasks/activities change or when minAwayMinutes setting changes.
    func rebuildTimelineItems() {
        let minIdleDuration = TimeInterval(SettingsManager.shared.minAwayMinutes * 60)
        timelineItems = TimelineItem.build(from: tasks, idleActivities: idleActivitiesForTimeline, minIdleDuration: minIdleDuration)
    }

    /// Lazy-load activities, screenshots, and file events for the Log view.
    /// Only loads if not already loaded for this date.
    func loadLogViewDataIfNeeded() {
        guard let db = dbReader else { return }

        if !activitiesLoaded {
            activities = db.activities(for: selectedDate)
            groupedActivities = ActivityGroup.group(activities)
            activitiesLoaded = true
        }

        if !screenshotsLoaded {
            screenshots = db.screenshots(for: selectedDate)
            screenshotsLoaded = true
        }

        if !fileEventsLoaded {
            fileEvents = db.fileEvents(for: selectedDate)
            fileEventsLoaded = true
        }
    }

    /// Attempt to load stubs content from the database for the selected date.
    /// If found, populates greetingContext, daySummaryContent, suggestedQuestions, and recommendations.
    private func loadPersistedStubs(from db: DatabaseReader) {
        let dateStr = SharedFormatters.dayFormatter.string(from: selectedDate)
        guard let record = db.stubsContent(for: selectedDate) else {
            Logger.info("loadPersistedStubs: no record for \(dateStr)")
            return
        }

        Logger.info("loadPersistedStubs: found record for \(dateStr), daySummary=\(record.daySummary != nil ? "present" : "nil")")
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

        // Load persisted day wrap metrics
        persistedFocusTime = record.focusTimeSeconds.map { TimeInterval($0) }
        persistedMeetingTime = record.meetingTimeSeconds.map { TimeInterval($0) }
        persistedProjectCount = record.projectCount

        // Mark as already loaded so auto-generate doesn't fire
        if !recommendations.isEmpty || daySummaryContent != nil {
            hasAttemptedStubsGeneration = true
            lastStubsTaskFingerprint = currentTaskFingerprint
            lastStubsGenerationTime = record.generatedAt
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
            do {
                try fm.removeItem(atPath: path)
            } catch {
                Logger.warning("Failed to delete screenshot at \(path): \(error.localizedDescription)")
            }
        }

        // Also clear the screenshots directory of any orphaned files
        if let config = try? SharedConfiguration() {
            let ssDir = config.screenshotDirectory
            if let files = try? fm.contentsOfDirectory(at: ssDir, includingPropertiesForKeys: nil) {
                for file in files {
                    do {
                        try fm.removeItem(at: file)
                    } catch {
                        Logger.warning("Failed to delete file \(file.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }

        // 3. Reset memory
        if let config = try? SharedConfiguration() {
            do {
                try fm.removeItem(at: config.memoryPath)
            } catch {
                Logger.warning("Failed to delete memory file: \(error.localizedDescription)")
            }
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
        timelineItems = []
        recommendations = []
        greetingContext = nil
        daySummaryContent = nil
        suggestedQuestions = []
        chatThreads = []
        activeThreadId = nil
        chatMessages = []
        chatError = nil
        activeSeconds = 0
        idleSeconds = 0
        daySummaryText = nil
        summaryError = nil
        recommendationsError = nil

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

        // Listen for menu bar chat triggers
        menuBarChatObserver = NotificationCenter.default.addObserver(
            forName: .menuBarChatQuestion,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let question = notification.userInfo?["question"] as? String else { return }
                self?.pendingChatQuestion = question
                self?.shouldExpandChatPanel = true
            }
        }
    }

    /// If the selected date is no longer today, auto-switch to today and reload.
    private func advanceToTodayIfNeeded() {
        guard !Calendar.current.isDateInToday(selectedDate) else {
            // Still today — just refresh data (daemon may have written new rows)
            loadAvailableDates()
            loadDataForSelectedDate()
            checkStubsStaleness()
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
                self.checkStubsStaleness()
                Logger.debug("Periodic dashboard refresh completed")
            }
        }
    }
}
