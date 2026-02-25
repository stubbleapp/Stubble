import Foundation
import TaskMinerShared

// MARK: - Recommendations

extension DashboardViewModel {

    /// Generate AI-powered stubs content based on recent work activity.
    /// For today: forward-looking recommendations. For past days: retrospective day summary.
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

        // Gather context
        let recentTasks = loadRecentTasksForSelectedDate(days: 3)
        let currentProjectActivities = projectActivities
        let appsUsed = buildAppUsageMap(from: recentTasks)
        let memoryContext = memoryStore.contextString()
        let activityLog = buildActivityLog()
        let viewingToday = isViewingToday
        let dateLabel = SharedFormatters.headerDateFormatter.string(from: selectedDate)
        let dateString = SharedFormatters.dayFormatter.string(from: selectedDate)

        Task {
            do {
                let content: StubsContent
                if viewingToday {
                    content = try await generator.generate(
                        recentTasks: recentTasks,
                        projectActivities: currentProjectActivities,
                        appsUsed: appsUsed,
                        memoryContext: memoryContext,
                        activityLog: activityLog
                    )
                } else {
                    content = try await generator.generateDaySummary(
                        recentTasks: recentTasks,
                        projectActivities: currentProjectActivities,
                        appsUsed: appsUsed,
                        memoryContext: memoryContext,
                        activityLog: activityLog,
                        dateLabel: dateLabel
                    )
                }

                // Always persist to database (keyed by the date we generated for)
                self.persistStubsContent(content, dateString: dateString)

                // Only update UI if still viewing the same date (user may have navigated away)
                let currentDateString = SharedFormatters.dayFormatter.string(from: self.selectedDate)
                if currentDateString == dateString {
                    self.recommendations = content.recommendations
                    self.greetingContext = content.greetingContext.isEmpty ? nil : content.greetingContext
                    self.daySummaryContent = content.daySummary
                    self.suggestedQuestions = content.suggestedQuestions
                }
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

    // MARK: - Persistence

    /// Serialize and persist stubs content to the database.
    private func persistStubsContent(_ content: StubsContent, dateString: String) {
        guard let writer = taskWriter else { return }

        // Serialize questions
        let questionsJson: String
        if let data = try? JSONSerialization.data(withJSONObject: content.suggestedQuestions),
           let str = String(data: data, encoding: .utf8) {
            questionsJson = str
        } else {
            questionsJson = "[]"
        }

        // Serialize recommendations
        let recsArray: [[String: Any]] = content.recommendations.map { rec in
            var dict: [String: Any] = [
                "category": rec.category.rawValue,
                "title": rec.title,
                "description": rec.description,
                "reason": rec.reason,
                "icon": rec.iconName
            ]
            if let url = rec.actionURL { dict["action_url"] = url }
            return dict
        }
        let recsJson: String
        if let data = try? JSONSerialization.data(withJSONObject: recsArray),
           let str = String(data: data, encoding: .utf8) {
            recsJson = str
        } else {
            recsJson = "[]"
        }

        let record = StubsContentRecord(
            date: dateString,
            greetingContext: content.greetingContext,
            daySummary: content.daySummary,
            questionsJson: questionsJson,
            recommendationsJson: recsJson
        )

        do {
            try writer.insertOrReplaceStubsContent(record)
        } catch {
            Logger.error("Failed to persist stubs content: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    /// Load tasks for the last N days centered around the selected date.
    private func loadRecentTasksForSelectedDate(days: Int) -> [String: [TaskRecord]] {
        guard let db = dbReader else { return [:] }
        let cal = Calendar.current
        var result: [String: [TaskRecord]] = [:]

        // Include selected date's tasks
        if !tasks.isEmpty {
            let dateStr = SharedFormatters.dayFormatter.string(from: selectedDate)
            result[dateStr] = tasks
        }

        // Add surrounding days for context
        for offset in 1..<days {
            guard let date = cal.date(byAdding: .day, value: -offset, to: selectedDate) else { continue }
            let dayTasks = db.tasks(for: date)
            if !dayTasks.isEmpty {
                let dateStr = SharedFormatters.dayFormatter.string(from: date)
                result[dateStr] = dayTasks
            }
        }

        return result
    }

    /// Build a compact activity log from the selected date's grouped activities, including window titles.
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

    // MARK: - Auto-Generate Past Day Summaries

    /// Automatically generate day summaries for recent past days that have activity data
    /// but no persisted stubs content. Called once on app launch (runs in background).
    func autoGeneratePendingSummaries() {
        guard let generator = recommendationGenerator,
              let db = dbReader else { return }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // Collect recent past days that need summaries (up to 7 days back)
        var datesToGenerate: [Date] = []
        for offset in 1...7 {
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let dayTasks = db.tasks(for: date)
            guard !dayTasks.isEmpty else { continue }
            // Skip if already persisted
            if db.stubsContent(for: date) != nil { continue }
            datesToGenerate.append(date)
        }

        guard !datesToGenerate.isEmpty else { return }
        Logger.info("Auto-generating day summaries for \(datesToGenerate.count) past day(s)")

        Task {
            for date in datesToGenerate {
                // Double-check not generated in the meantime (e.g. user navigated to that date)
                if db.stubsContent(for: date) != nil { continue }
                await generateSummaryForDate(date, generator: generator, db: db)
            }
            // If user is currently viewing one of the generated dates, reload stubs
            let selectedStart = cal.startOfDay(for: selectedDate)
            if datesToGenerate.contains(where: { cal.isDate($0, inSameDayAs: selectedStart) }) {
                loadDataForSelectedDate()
            }
        }
    }

    /// Generate and persist a day summary for a specific past date.
    /// Runs independently of selectedDate — loads all needed data directly from the DB.
    private func generateSummaryForDate(_ date: Date, generator: RecommendationGenerator, db: DatabaseReader) async {
        let targetTasks = db.tasks(for: date)
        guard !targetTasks.isEmpty else { return }

        let cal = Calendar.current
        let dateStr = SharedFormatters.dayFormatter.string(from: date)
        let dateLabel = SharedFormatters.headerDateFormatter.string(from: date)

        // Build recent tasks map (target date + 2 prior days for context)
        var recentTasks: [String: [TaskRecord]] = [dateStr: targetTasks]
        for offset in 1..<3 {
            guard let d = cal.date(byAdding: .day, value: -offset, to: date) else { continue }
            let dayTasks = db.tasks(for: d)
            if !dayTasks.isEmpty {
                recentTasks[SharedFormatters.dayFormatter.string(from: d)] = dayTasks
            }
        }

        // Load activities and project activities for the target date
        let dateActivities = db.activities(for: date)
        let grouped = ActivityGroup.group(dateActivities)
        let paRecords = db.projectActivities(for: date)
        let pas = paRecords.map { ProjectActivity(from: $0) }

        // Build activity log from grouped activities
        var activityLog: String? = nil
        if !grouped.isEmpty {
            var lines: [String] = []
            for group in grouped {
                let start = group.startTime.map { SharedFormatters.timeFormatter.string(from: $0) } ?? "?"
                let end = group.endTime.map { SharedFormatters.timeFormatter.string(from: $0) } ?? "?"
                let durMins = Int(group.totalDuration) / 60
                lines.append("- [\(start)–\(end)] \(group.appName) (\(durMins)m)")
                for title in group.windowTitles.prefix(3) {
                    lines.append("  · \(title)")
                }
            }
            activityLog = lines.joined(separator: "\n")
        }

        let appsUsed = buildAppUsageMap(from: recentTasks)
        let memoryContext = memoryStore.contextString()

        do {
            let content = try await generator.generateDaySummary(
                recentTasks: recentTasks,
                projectActivities: pas,
                appsUsed: appsUsed,
                memoryContext: memoryContext,
                activityLog: activityLog,
                dateLabel: dateLabel
            )
            persistStubsContent(content, dateString: dateStr)
            Logger.info("Auto-generated day summary for \(dateStr)")
        } catch {
            Logger.error("Failed to auto-generate summary for \(dateStr): \(error.localizedDescription)")
        }
    }
}
