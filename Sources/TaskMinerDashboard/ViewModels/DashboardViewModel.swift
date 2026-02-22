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
    var hasGeminiKey: Bool

    // AI day summary (generated alongside tasks)
    var daySummaryText: String?

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
            self.taskSummarizer = TaskSummarizer(geminiClient: client)
            self.hasGeminiKey = true
        } else {
            self.taskSummarizer = nil
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
        let dateStr = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: date)
        }()

        let memoryContext = memoryStore.contextString()

        Task {
            do {
                let result = try await summarizer.summarize(
                    activities: activityData,
                    date: date,
                    customPrompt: SettingsManager.shared.customPrompt,
                    memoryContext: memoryContext
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
            self.taskSummarizer = TaskSummarizer(geminiClient: client)
            self.hasGeminiKey = true
        } else {
            self.taskSummarizer = nil
            self.hasGeminiKey = false
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
