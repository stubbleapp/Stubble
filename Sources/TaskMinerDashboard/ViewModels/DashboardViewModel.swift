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

    /// Brief loading state shown during date changes (data loading)
    var isLoadingDateData = false

    // Cached timeline items (tasks + gaps) — rebuilt when tasks/activities change
    var timelineItems: [TimelineItem] = []
    /// Whether AI features are available (user is signed in with valid subscription).
    var hasAIAccess: Bool

    // AI day summary (generated alongside tasks; persisted in `day_wrap` for reloads)
    var daySummaryText: String?

    // Project activities (AI-clustered from tasks)
    var projectActivities: [ProjectActivity] = []
    /// All unique projects from the database (for matching project names in summaries).
    /// Pre-loaded during init via loadAllKnownProjects() - never query during view rendering.
    private(set) var allKnownProjects: [ProjectActivity] = []
    var isGeneratingActivities = false
    var activitiesError: String?
    var activityGenerator: ProjectActivityGenerator?

    /// Cached color assignments for all project activities (collision-resolved)
    private var _resolvedProjectColors: [UUID: Color] = [:]

    /// Cached color assignments for all aggregated projects (collision-resolved)
    private var _resolvedAggregatedColors: [UUID: Color] = [:]

    /// Whether the user is viewing today's date or a past day (affects Day Wrap timing).
    var isViewingToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    /// Whether debug mode is active (Option key held). Set by ContentView.
    var isDebugMode: Bool = false

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
    /// Set by ChatOverlayView to trigger a chat question.
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

    // Cache of activities for the selected date (for app duration sorting in DashboardViewModel+Activities)
    var cachedActivitiesDate: String = ""
    var cachedActivities: [ActivityRecord] = []

    // In-flight AI task handles (for cancellation on new request)
    var summaryTask: Task<Void, Never>?

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

        // Initialize AI client for signed-in users.
        // Skip if setup wizard hasn't completed yet.
        if SettingsManager.shared.hasCompletedSetup, let client = GeminiClient.resolvedClient() {
            self.geminiClient = client
            self.taskSummarizer = TaskSummarizer(geminiClient: client)
            self.activityGenerator = ProjectActivityGenerator(geminiClient: client)
            self.hasAIAccess = true
        } else {
            self.geminiClient = nil
            self.taskSummarizer = nil
            self.activityGenerator = nil
            self.hasAIAccess = false
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
        loadAllKnownProjects()
        startPausePolling()
        startPeriodicRefresh()
        observeSystemWake()
    }

    /// Task handle for cancelling in-flight date loading when user rapidly switches dates
    private var dateLoadingTask: Task<Void, Never>?

    func selectDate(_ date: Date) {
        // Cancel any in-flight date loading
        dateLoadingTask?.cancel()

        // Cancel any in-flight summary regeneration for the previous date
        summaryTask?.cancel()
        isGeneratingSummary = false
        summaryError = nil

        // Immediate UI update — date pill reflects selection instantly
        selectedDate = date

        // Clear stale state without triggering expensive recomputations
        daySummaryText = nil
        clearAppDurationCache()

        // Clear timeline immediately for snappier feel (will be rebuilt after load)
        tasks = []
        projectActivities = []
        timelineItems = []
        isLoadingDateData = true

        // Load data asynchronously to avoid blocking the main thread
        dateLoadingTask = Task {
            // Small yield to let SwiftUI update the date selector first
            await Task.yield()

            guard !Task.isCancelled else { return }

            loadDataForSelectedDate()
            isLoadingDateData = false
        }
    }

    // MARK: - AI Summary Generation

    func generateSummary() {
        guard let summarizer = taskSummarizer,
              let db = dbReader,
              let writer = taskWriter
        else {
            summaryError = "Sign in required for AI features"
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

        // Cancel any in-flight summary task before starting a new one
        summaryTask?.cancel()
        summaryTask = Task {
            do {
                let currentGranularity = SettingsManager.shared.granularity
                Logger.info("Generating summary with granularity: \(currentGranularity.rawValue)")
                let result = try await summarizer.summarize(
                    activities: activityData,
                    date: date,
                    customPrompt: SettingsManager.shared.customPrompt,
                    memoryContext: memoryContext,
                    granularity: currentGranularity,
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
                    self.persistProjectActivities(ProjectActivityGenerator.fallbackActivities(from: result.tasks), dateStr: dateStr)
                }

                // Persist day narrative so it survives date switches / app restarts.
                try writer.insertOrReplaceDayWrap(DayWrapRecord(
                    date: dateStr,
                    summary: result.daySummary,
                    focusTimeSeconds: nil,
                    meetingTimeSeconds: nil,
                    projectCount: nil,
                    updatedAt: Date()
                ))

                // Merge new structured memory entries and re-synthesize profile
                if !result.newMemoryEntries.isEmpty {
                    self.memoryStore.mergeStructured(newEntries: result.newMemoryEntries)
                    let profileSynth = ProfileSynthesizer(geminiClient: summarizer.geminiClient)
                    await profileSynth.synthesizeIfNeeded(store: self.memoryStore)
                }

                // Targeted refresh: only reload what changed (tasks + project activities)
                // Avoid full loadDataForSelectedDate() which resets many arrays and causes visual disruption
                self.refreshTasksAndProjects()
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
            self.hasAIAccess = true
            // Update sub-view-models
            self.chatVM.geminiClient = client
        } else {
            self.geminiClient = nil
            self.taskSummarizer = nil
            self.activityGenerator = nil
            self.hasAIAccess = false
            // Clear sub-view-models
            self.chatVM.geminiClient = nil
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

    /// Resolves colors for ALL project activities using linear probing.
    /// Sorted by duration so most visible projects get their preferred colors.
    /// When more activities than palette colors, colors are reused.
    private func resolveAllProjectColors() {
        let palette = Theme.barPalette
        var usedIndices = Set<Int>()
        _resolvedProjectColors = [:]

        let sorted = projectActivities.sorted { $0.totalDuration > $1.totalDuration }

        for activity in sorted {
            var idx = activity.colorIndex % palette.count
            // Only try to find unused color if we haven't exhausted the palette
            if usedIndices.count < palette.count {
                var attempts = 0
                while usedIndices.contains(idx) && attempts < palette.count {
                    idx = (idx + 1) % palette.count
                    attempts += 1
                }
                usedIndices.insert(idx)
            }
            // If palette exhausted, just use the hash-based index (colors will repeat)
            _resolvedProjectColors[activity.id] = palette[idx]
        }
    }

    /// Resolves colors for ALL aggregated projects using linear probing.
    /// Sorted by duration so most visible projects get their preferred colors.
    /// When more projects than palette colors, colors are reused.
    func resolveAggregatedProjectColors() {
        let palette = Theme.barPalette
        var usedIndices = Set<Int>()
        _resolvedAggregatedColors = [:]

        let sorted = aggregatedProjects.sorted { $0.totalDuration > $1.totalDuration }

        for project in sorted {
            var idx = project.colorIndex % palette.count
            // Only try to find unused color if we haven't exhausted the palette
            if usedIndices.count < palette.count {
                var attempts = 0
                while usedIndices.contains(idx) && attempts < palette.count {
                    idx = (idx + 1) % palette.count
                    attempts += 1
                }
                usedIndices.insert(idx)
            }
            // If palette exhausted, just use the hash-based index (colors will repeat)
            _resolvedAggregatedColors[project.id] = palette[idx]
        }
    }

    /// Top-3 activities by duration, using resolved colors from the cache.
    private var resolvedTop3: [(activity: ProjectActivity, color: Color)] {
        let sorted = projectActivities.sorted { $0.totalDuration > $1.totalDuration }
        return sorted.prefix(3).compactMap { activity in
            guard let color = _resolvedProjectColors[activity.id] else { return nil }
            return (activity, color)
        }
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

    /// Returns the resolved color for a given project activity.
    /// Uses the cached collision-resolved color for all projects.
    func resolvedColor(for activity: ProjectActivity) -> Color {
        _resolvedProjectColors[activity.id] ?? Theme.barPalette[activity.colorIndex % Theme.barPalette.count]
    }

    /// Returns the resolved color for a given aggregated project.
    /// Uses the cached collision-resolved color for all projects.
    func resolvedAggregatedColor(for project: AggregatedProject) -> Color {
        _resolvedAggregatedColors[project.id] ?? Theme.barPalette[project.colorIndex % Theme.barPalette.count]
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

    private func loadAllKnownProjects() {
        guard let db = dbReader else { return }
        let records = db.allUniqueProjectActivities()
        allKnownProjects = records.map { ProjectActivity(from: $0) }
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

        // Resolve colors for all project activities (collision-free)
        resolveAllProjectColors()

        // Load persisted day wrap narrative + metrics (from `day_wrap`, with legacy stubs fallback)
        loadPersistedDayWrap(from: db)

        // Rebuild cached timeline items
        rebuildTimelineItems()
    }

    /// Rebuild the cached timeline items from current tasks and activities.
    /// Call this after tasks/activities change or when minAwayMinutes setting changes.
    func rebuildTimelineItems() {
        let minIdleDuration = TimeInterval(SettingsManager.shared.minAwayMinutes * 60)
        timelineItems = TimelineItem.build(from: tasks, idleActivities: idleActivitiesForTimeline, minIdleDuration: minIdleDuration)
    }

    /// Targeted refresh of tasks and project activities only.
    /// Use after task regeneration to avoid the broader state changes from loadDataForSelectedDate().
    private func refreshTasksAndProjects() {
        guard let db = dbReader else { return }

        // Reload tasks and idle activities
        tasks = db.tasks(for: selectedDate)
        idleActivitiesForTimeline = db.idleActivities(for: selectedDate)

        // Reload project activities
        let paRecords = db.projectActivities(for: selectedDate)
        projectActivities = paRecords.map { ProjectActivity(from: $0) }

        // Resolve colors for all project activities (collision-free)
        resolveAllProjectColors()

        // Rebuild timeline
        rebuildTimelineItems()
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

    /// Load the persisted day narrative so it survives date switches and app restarts.
    private func loadPersistedDayWrap(from db: DatabaseReader) {
        let dateStr = SharedFormatters.dayFormatter.string(from: selectedDate)
        guard let wrap = db.timelineDayWrap(for: selectedDate) else {
            Logger.info("loadPersistedDayWrap: no record for \(dateStr)")
            return
        }
        Logger.info("loadPersistedDayWrap: found record for \(dateStr), summary=\(wrap.summary != nil ? "present" : "nil")")
        if let s = wrap.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            daySummaryText = s
        }
    }

    // MARK: - Clear All Data

    /// Erase all tasks, activities, screenshots, and memory. Keeps settings and auth state.
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
        chatThreads = []
        activeThreadId = nil
        chatMessages = []
        chatError = nil
        activeSeconds = 0
        idleSeconds = 0
        daySummaryText = nil
        summaryError = nil

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

    // MARK: - OCR Digest

    /// Load the cached OCR digest for the selected date, or build it on-demand from DB.
    func loadOrBuildOCRDigest() -> String? {
        guard let db = dbReader else { return nil }
        // Try cached first
        if let cached = db.ocrDigest(for: selectedDate) {
            return cached
        }
        // Build on-demand from whatever OCR texts are in the DB
        let ocrTexts = db.ocrTextsForDate(selectedDate)
        guard !ocrTexts.isEmpty else { return nil }
        let digest = OCRDigestBuilder.buildDigest(from: ocrTexts)
        guard let section = digest.asPromptSection() else { return nil }
        // Cache it
        let dateStr = SharedFormatters.dayFormatter.string(from: selectedDate)
        db.insertOrReplaceOCRDigest(date: dateStr, digest: section)
        return section
    }
}
