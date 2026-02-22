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
    private let taskWriter: TaskWriter?
    private var taskSummarizer: TaskSummarizer?
    private var geminiClient: GeminiClient?
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
    private var activityGenerator: ProjectActivityGenerator?

    // Chat
    var chatMessages: [ChatMessage] = []
    var isChatLoading = false
    var chatError: String?

    // App name → bundle ID mapping (for icon resolution)
    var appNameBundleMap: [String: String] = [:]

    // Pause
    var pauseState: PauseState?
    private var pauseTimer: Timer?

    deinit {
        // View model is owned by the view hierarchy and deallocated on the main thread.
        MainActor.assumeIsolated {
            pauseTimer?.invalidate()
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
        self.dbReader = config.flatMap { try? DatabaseReader(path: $0.databasePath) }
        self.pauseController = PauseController(dataDirectory: baseDir)
        self.taskWriter = config.flatMap { try? TaskWriter(path: $0.databasePath) }
        self.memoryStore = UserMemoryStore(filePath: config?.memoryPath ?? baseDir.appendingPathComponent("memory.json"))

        // Initialize AI summarization: Keychain first, then env (same as CLI)
        let geminiClient = GeminiClient.resolvedClient()

        if let client = geminiClient {
            self.geminiClient = client
            self.taskSummarizer = TaskSummarizer(geminiClient: client)
            self.activityGenerator = ProjectActivityGenerator(geminiClient: client)
            self.hasGeminiKey = true
        } else {
            self.geminiClient = nil
            self.taskSummarizer = nil
            self.activityGenerator = nil
            self.hasGeminiKey = false
        }

        loadAvailableDates()
        loadDataForSelectedDate()
        loadAppNameMap()
        startPausePolling()
    }

    func selectDate(_ date: Date) {
        selectedDate = date
        daySummaryText = nil
        clearChat()
        loadDataForSelectedDate()
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

        Task {
            do {
                let result = try await summarizer.summarize(
                    activities: activityData,
                    date: date,
                    customPrompt: SettingsManager.shared.customPrompt,
                    memoryContext: memoryContext,
                    granularity: SettingsManager.shared.granularity
                )

                try writer.deleteTasks(for: dateStr)
                try writer.insertTasks(result.tasks)

                // Merge any new memory entries learned from this session
                if !result.newMemoryEntries.isEmpty {
                    self.memoryStore.merge(newEntries: result.newMemoryEntries)
                }

                // Refresh all data for the day (tasks, activities, summary stats)
                self.loadDataForSelectedDate()
                self.daySummaryText = result.daySummary
                self.isGeneratingSummary = false

                // Also regenerate project activities now that tasks are fresh
                self.generateProjectActivities(forceRegenerate: true)
            } catch {
                self.summaryError = error.localizedDescription
                self.isGeneratingSummary = false
            }
        }
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
            self.hasGeminiKey = true
        } else {
            self.geminiClient = nil
            self.taskSummarizer = nil
            self.activityGenerator = nil
            self.hasGeminiKey = false
        }
    }

    // MARK: - Chat

    private static let chatTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    func sendChatMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client = geminiClient else {
            chatError = "Gemini API key not configured"
            return
        }

        chatMessages.append(ChatMessage(role: .user, content: trimmed))
        isChatLoading = true
        chatError = nil

        // Capture context for the async task
        let taskContext = buildChatTaskContext()
        let memoryContext = memoryStore.contextString()
        let history = buildConversationHistory()

        Task {
            do {
                let systemInstruction = """
                You are a helpful assistant embedded in a desktop activity tracker called TaskMiner. \
                You answer questions about the user's computer activity and tasks for the day. \
                Be concise and conversational — keep responses short unless asked for detail. \
                Use the provided task data and activity context to give accurate answers. \
                If the user asks about time, calculate it from the task start/end times provided. \
                Format durations as hours and minutes (e.g. "2h 15m"). \
                Never make up tasks or times that aren't in the context. \
                If you don't have enough information, say so.
                """

                let prompt = """
                Today's tasks and activity context:
                \(taskContext)
                \(memoryContext.map { "User context: \($0)" } ?? "")

                \(trimmed)
                """

                let response = try await client.generateText(
                    prompt: prompt,
                    systemInstruction: systemInstruction,
                    conversationHistory: history
                )

                self.chatMessages.append(ChatMessage(role: .assistant, content: response))
                self.isChatLoading = false
            } catch {
                self.chatError = error.localizedDescription
                self.isChatLoading = false
            }
        }
    }

    func clearChat() {
        chatMessages = []
        chatError = nil
        isChatLoading = false
    }

    /// Build a text block summarizing the current day's tasks for chat context.
    private func buildChatTaskContext() -> String {
        guard !tasks.isEmpty else { return "No tasks recorded for this day." }

        var lines: [String] = []
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "EEEE, MMMM d, yyyy"
        lines.append("Date: \(dateFmt.string(from: selectedDate))")

        if let summary = daySummaryText {
            lines.append("Day summary: \(summary)")
        }

        let totalActive = Int(activeSeconds)
        let hours = totalActive / 3600
        let mins = (totalActive % 3600) / 60
        lines.append("Total active time: \(hours)h \(mins)m")
        lines.append("")
        lines.append("Tasks:")

        for task in tasks {
            let start = Self.chatTimeFmt.string(from: task.startTime)
            let end = Self.chatTimeFmt.string(from: task.endTime)
            let duration = Int(task.endTime.timeIntervalSince(task.startTime))
            let durMins = duration / 60
            let apps = task.appNamesList.joined(separator: ", ")
            lines.append("- [\(start)–\(end)] (\(durMins)m) \(task.title)")
            if !task.description.isEmpty {
                lines.append("  \(task.description)")
            }
            if !apps.isEmpty {
                lines.append("  Apps: \(apps)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Build Gemini-compatible conversation history from previous messages (excluding the latest user message).
    private func buildConversationHistory() -> [[String: Any]]? {
        // All messages except the last one (which is the new user message sent as the prompt)
        let previous = chatMessages.dropLast()
        guard !previous.isEmpty else { return nil }

        return previous.map { msg in
            [
                "role": msg.role == .user ? "user" : "model",
                "parts": [["text": msg.content]]
            ] as [String: Any]
        }
    }

    // MARK: - Export

    /// Build CSV content from the current task list.
    func tasksCSV() -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        var lines: [String] = []
        lines.append("Date,Start,End,Duration,Title,Description,Apps,Confidence")

        for task in tasks {
            let date = task.date
            let start = timeFmt.string(from: task.startTime)
            let end = timeFmt.string(from: task.endTime)
            let duration = Int(task.endTime.timeIntervalSince(task.startTime))
            let mins = duration / 60
            let secs = duration % 60
            let durStr = String(format: "%d:%02d", mins, secs)
            let title = csvEscape(task.title)
            let desc = csvEscape(task.description)
            let apps = csvEscape(task.appNamesList.joined(separator: ", "))
            let conf = String(format: "%.0f%%", task.confidence * 100)
            lines.append("\(date),\(start),\(end),\(durStr),\(title),\(desc),\(apps),\(conf)")
        }

        return lines.joined(separator: "\n")
    }

    /// Export tasks as CSV via NSSavePanel.
    func exportTasksCSV() {
        guard !tasks.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "tasks-\(tasks.first?.date ?? "export").csv"
        panel.title = "Export Tasks"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try tasksCSV().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            summaryError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    // MARK: - Pause

    func pause(for duration: TimeInterval?) {
        pauseController.pause(for: duration)
        pauseState = pauseController.currentState()
    }

    func resumeMonitoring() {
        pauseController.resume()
        pauseState = nil
    }

    // MARK: - Project Activities

    /// Generate project activities by clustering tasks via AI.
    /// Results are persisted to the database. Only regenerates when explicitly requested.
    func generateProjectActivities(forceRegenerate: Bool = false) {
        let dateStr = SharedFormatters.dayFormatter.string(from: selectedDate)

        // Need tasks to cluster
        guard !tasks.isEmpty else {
            projectActivities = []
            return
        }

        guard let generator = activityGenerator, taskWriter != nil else {
            // No AI available — fallback: one project per task, persist
            let fallback = ProjectActivityGenerator.fallbackActivities(from: tasks)
            projectActivities = fallback
            persistProjectActivities(fallback, dateStr: dateStr)
            return
        }

        isGeneratingActivities = true
        activitiesError = nil

        let todayTasks = tasks
        let recentTasks = loadRecentTasks(excluding: selectedDate, days: 7)
        let memoryContext = memoryStore.contextString()

        Task {
            do {
                let activities = try await generator.cluster(
                    todayTasks: todayTasks,
                    recentHistory: recentTasks,
                    memoryContext: memoryContext
                )
                self.projectActivities = activities
                self.persistProjectActivities(activities, dateStr: dateStr)
                self.isGeneratingActivities = false
            } catch {
                self.activitiesError = error.localizedDescription
                // Fallback to ungrouped
                let fallback = ProjectActivityGenerator.fallbackActivities(from: todayTasks)
                self.projectActivities = fallback
                self.persistProjectActivities(fallback, dateStr: dateStr)
                self.isGeneratingActivities = false
            }
        }
    }

    /// Persist project activities to the database (delete + re-insert).
    private func persistProjectActivities(_ activities: [ProjectActivity], dateStr: String) {
        guard let writer = taskWriter else { return }
        do {
            try writer.deleteProjectActivities(for: dateStr)
            let records = activities.map { $0.toRecord(date: dateStr) }
            try writer.insertProjectActivities(records)
        } catch {
            Logger.error("Failed to persist project activities: \(error.localizedDescription)")
        }
    }

    /// Load tasks for the past N days (used as multi-day context for project clustering).
    private func loadRecentTasks(excluding currentDate: Date, days: Int) -> [String: [TaskRecord]] {
        guard let db = dbReader else { return [:] }
        let cal = Calendar.current
        var result: [String: [TaskRecord]] = [:]
        for offset in 1...days {
            guard let date = cal.date(byAdding: .day, value: -offset, to: currentDate) else { continue }
            let tasks = db.tasks(for: date)
            if !tasks.isEmpty {
                let dateStr = SharedFormatters.dayFormatter.string(from: date)
                result[dateStr] = tasks
            }
        }
        return result
    }

    /// Reload project activities from the database.
    private func reloadProjectActivities() {
        guard let db = dbReader else { return }
        let records = db.projectActivities(for: selectedDate)
        projectActivities = records.map { ProjectActivity(from: $0) }
    }

    // MARK: - Private

    private func loadAvailableDates() {
        availableDates = dbReader?.datesWithData() ?? []
    }

    private func loadAppNameMap() {
        appNameBundleMap = dbReader?.appNameToBundleIdMap() ?? [:]
    }

    /// Resolve an app display name to its bundle identifier for icon lookup.
    func bundleId(forAppName name: String) -> String? {
        appNameBundleMap[name]
    }

    private func loadDataForSelectedDate() {
        guard let db = dbReader else { return }

        activities = db.activities(for: selectedDate)
        groupedActivities = ActivityGroup.group(activities)
        screenshots = db.screenshots(for: selectedDate)
        tasks = db.tasks(for: selectedDate)

        let summary = db.computeSummary(for: selectedDate)
        activeSeconds = summary.activeSeconds
        idleSeconds = summary.idleSeconds

        // Load persisted project activities
        let paRecords = db.projectActivities(for: selectedDate)
        projectActivities = paRecords.map { ProjectActivity(from: $0) }
    }

    private func startPausePolling() {
        pauseState = pauseController.currentState()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pauseState = self?.pauseController.currentState()
            }
        }
    }
}
