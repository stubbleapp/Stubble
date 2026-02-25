import Foundation
import TaskMinerShared

// MARK: - Recommendations

extension DashboardViewModel {

    /// Generate AI-powered recommendations based on recent work activity.
    func generateRecommendations() {
        guard let generator = recommendationGenerator else {
            recommendationsError = "Gemini API key not configured"
            return
        }
        guard dbReader != nil else {
            recommendationsError = "Database unavailable"
            return
        }

        isGeneratingRecommendations = true
        recommendationsError = nil

        // Gather multi-day context: tasks from the last 3 days
        let recentTasks = loadRecentTasksIncludingToday(days: 3)

        // Current project activities
        let currentProjectActivities = projectActivities

        // Build app usage map from all recent tasks
        let appsUsed = buildAppUsageMap(from: recentTasks)

        // Memory context
        let memoryContext = memoryStore.contextString()

        // Build granular activity log for richer recommendations
        let activityLog = buildActivityLog()

        Task {
            do {
                let content = try await generator.generate(
                    recentTasks: recentTasks,
                    projectActivities: currentProjectActivities,
                    appsUsed: appsUsed,
                    memoryContext: memoryContext,
                    activityLog: activityLog
                )
                self.recommendations = content.recommendations
                self.greetingContext = content.greetingContext.isEmpty ? nil : content.greetingContext
                self.suggestedQuestions = content.suggestedQuestions
                self.isGeneratingRecommendations = false
                Analytics.recommendationsGenerated(count: content.recommendations.count)
            } catch {
                self.recommendationsError = error.localizedDescription
                self.isGeneratingRecommendations = false
            }
        }
    }

    /// Remove a single recommendation from the list.
    func dismissRecommendation(id: UUID) {
        recommendations.removeAll { $0.id == id }
    }

    // MARK: - Private Helpers

    /// Load tasks for the last N days INCLUDING today.
    private func loadRecentTasksIncludingToday(days: Int) -> [String: [TaskRecord]] {
        guard let db = dbReader else { return [:] }
        let cal = Calendar.current
        var result: [String: [TaskRecord]] = [:]

        // Include today's tasks
        if !tasks.isEmpty {
            let todayStr = SharedFormatters.dayFormatter.string(from: selectedDate)
            result[todayStr] = tasks
        }

        // Add previous days
        for offset in 1..<days {
            guard let date = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let dayTasks = db.tasks(for: date)
            if !dayTasks.isEmpty {
                let dateStr = SharedFormatters.dayFormatter.string(from: date)
                result[dateStr] = dayTasks
            }
        }

        return result
    }

    /// Build a compact activity log from today's grouped activities, including window titles.
    /// This gives recommendations access to the same granular detail as chat — specific documents,
    /// URLs, repo names, etc. — which produces much more relevant suggestions.
    private func buildActivityLog() -> String? {
        guard !groupedActivities.isEmpty else { return nil }
        var lines: [String] = []
        for group in groupedActivities {
            let start = group.startTime.map { SharedFormatters.timeFormatter.string(from: $0) } ?? "?"
            let end = group.endTime.map { SharedFormatters.timeFormatter.string(from: $0) } ?? "?"
            let durMins = Int(group.totalDuration) / 60
            lines.append("- [\(start)–\(end)] \(group.appName) (\(durMins)m)")
            for title in group.windowTitles.prefix(3) {
                lines.append("  · \(title)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Build a map of app name → total seconds used across all provided tasks.
    private func buildAppUsageMap(from recentTasks: [String: [TaskRecord]]) -> [String: TimeInterval] {
        var appTime: [String: TimeInterval] = [:]
        for (_, tasks) in recentTasks {
            for task in tasks {
                let perApp = task.duration / max(1, Double(task.appNamesList.count))
                for app in task.appNamesList {
                    appTime[app, default: 0] += perApp
                }
            }
        }
        return appTime
    }
}
