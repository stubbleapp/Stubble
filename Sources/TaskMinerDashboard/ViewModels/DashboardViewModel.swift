import Foundation
import SwiftUI
import TaskMinerShared

@Observable
@MainActor
final class DashboardViewModel {
    let config = SharedConfiguration()
    let dbReader: DatabaseReader?
    let pauseController: PauseController
    private let taskWriter: TaskWriter?
    private var taskSummarizer: TaskSummarizer?

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

    // App name → bundle ID mapping (for icon resolution)
    var appNameBundleMap: [String: String] = [:]

    // Pause
    var pauseState: PauseState?
    private var pauseTimer: Timer?

    init() {
        self.dbReader = try? DatabaseReader(path: config.databasePath)
        self.pauseController = PauseController(dataDirectory: config.dataDirectory)
        self.taskWriter = try? TaskWriter(path: config.databasePath)

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
        loadDataForSelectedDate()
    }

    func refresh() {
        loadAvailableDates()
        loadDataForSelectedDate()
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

        Task {
            do {
                let newTasks = try await summarizer.summarize(
                    activities: activityData,
                    date: date
                )

                // Delete old tasks for this date and insert new ones
                writer.deleteTasks(for: dateStr)
                writer.insertTasks(newTasks)

                // Reload tasks from DB
                self.tasks = db.tasks(for: date)
                self.isGeneratingSummary = false
            } catch {
                self.summaryError = error.localizedDescription
                self.isGeneratingSummary = false
            }
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
