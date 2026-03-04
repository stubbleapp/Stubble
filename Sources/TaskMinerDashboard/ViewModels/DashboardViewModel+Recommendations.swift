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

        // Gather context — wide window for richer recommendations
        let recentTasks = loadRecentTasksForSelectedDate(days: 7)
        let currentProjectActivities = projectActivities
        let appsUsed = buildAppUsageMap(from: recentTasks)
        let activityLog = buildActivityLog()
        let weeklyTrends = buildWeeklyTrends(from: recentTasks)
        let ocrDigest = loadOrBuildOCRDigest()
        let viewingToday = isViewingToday
        let dateLabel = SharedFormatters.headerDateFormatter.string(from: selectedDate)
        let dateString = SharedFormatters.dayFormatter.string(from: selectedDate)

        // Capture the task fingerprint at generation time so we can track staleness
        let fingerprintAtGeneration = currentTaskFingerprint

        recommendationsTask?.cancel()
        recommendationsTask = Task {
            do {
                // Ensure user profile is fresh before generating recommendations
                if let client = self.geminiClient {
                    let synth = ProfileSynthesizer(geminiClient: client)
                    await synth.synthesizeIfNeeded(store: self.memoryStore)
                }
                guard !Task.isCancelled else { return }
                let memoryContext = self.memoryStore.contextString()

                // Capture all values needed by the sendable closure before entering the timeout
                let capturedGenerator = generator
                let capturedRecentTasks = recentTasks
                let capturedProjectActivities = currentProjectActivities
                let capturedAppsUsed = appsUsed
                let capturedMemoryContext = memoryContext
                let capturedActivityLog = activityLog
                let capturedWeeklyTrends = weeklyTrends
                let capturedOcrDigest = ocrDigest
                let capturedDateLabel = dateLabel
                let capturedViewingToday = viewingToday

                let content = try await withThrowingTimeout(seconds: 90) {
                    if capturedViewingToday {
                        return try await capturedGenerator.generate(
                            recentTasks: capturedRecentTasks,
                            projectActivities: capturedProjectActivities,
                            appsUsed: capturedAppsUsed,
                            memoryContext: capturedMemoryContext,
                            activityLog: capturedActivityLog,
                            weeklyTrends: capturedWeeklyTrends,
                            ocrDigest: capturedOcrDigest
                        )
                    } else {
                        return try await capturedGenerator.generateDaySummary(
                            recentTasks: capturedRecentTasks,
                            projectActivities: capturedProjectActivities,
                            appsUsed: capturedAppsUsed,
                            memoryContext: capturedMemoryContext,
                            activityLog: capturedActivityLog,
                            weeklyTrends: capturedWeeklyTrends,
                            ocrDigest: capturedOcrDigest,
                            dateLabel: capturedDateLabel
                        )
                    }
                }

                guard !Task.isCancelled else { return }

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
                self.lastStubsTaskFingerprint = fingerprintAtGeneration
                self.lastStubsGenerationTime = Date()
                Analytics.recommendationsGenerated(count: content.recommendations.count)
            } catch is CancellationError {
                // Task was cancelled (e.g. user navigated away) — don't set error
                self.isGeneratingRecommendations = false
            } catch {
                self.recommendationsError = Self.friendlyRecommendationsError(error)
                self.isGeneratingRecommendations = false
                Logger.error("Stubs generation failed: \(error.localizedDescription)")
            }
        }
    }

    /// Remove a single recommendation from the list.
    func dismissRecommendation(id: UUID) {
        recommendations.removeAll { $0.id == id }
    }

    // MARK: - Auto-Refresh Staleness Check

    /// Check whether stubs should be auto-refreshed based on task data changes.
    /// Called from the periodic refresh timer after loading fresh data from the DB.
    func checkStubsStaleness() {
        // Only auto-refresh for today's date
        guard isViewingToday else { return }

        // Only if stubs have been generated at least once
        guard hasAttemptedStubsGeneration else { return }

        // Don't interrupt an in-progress generation
        guard !isGeneratingRecommendations else { return }

        // Need an API key and tasks to work with
        guard hasGeminiKey, !tasks.isEmpty else { return }

        // Enforce minimum interval between auto-refreshes
        let elapsed = Date().timeIntervalSince(lastStubsGenerationTime)
        guard elapsed >= Self.minStubsRefreshInterval else { return }

        // Compare task fingerprints — skip if data hasn't changed
        let fingerprint = currentTaskFingerprint
        guard fingerprint != lastStubsTaskFingerprint else { return }

        Logger.debug("Stubs data changed (\(lastStubsTaskFingerprint) → \(fingerprint)) — auto-refreshing")
        generateRecommendations()
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

    /// Analyze cross-day patterns: recurring projects, time distribution shifts, focus trends.
    /// Uses actual project activity data from the DB rather than regex-based keyword extraction.
    private func buildWeeklyTrends(from recentTasks: [String: [TaskRecord]]) -> String? {
        guard recentTasks.count >= 2 else { return nil }

        let formatter = SharedFormatters.dayFormatter
        var projectDays: [String: Int] = [:]
        var projectMinutes: [String: Double] = [:]
        var dailyHours: [(date: String, hours: Double)] = []
        var topicDays: [String: Int] = [:]

        for (dateStr, tasks) in recentTasks {
            let totalSecs = tasks.reduce(0.0) { $0 + $1.duration }
            dailyHours.append((dateStr, totalSecs / 3600))

            // Use real project activities from the DB for this date
            if let db = dbReader, let date = formatter.date(from: dateStr) {
                let paRecords = db.projectActivities(for: date)
                for pa in paRecords {
                    let name = pa.name
                    projectDays[name, default: 0] += 1
                    projectMinutes[name, default: 0] += pa.totalDuration / 60
                }
            }

            // Also extract recurring themes from task descriptions for richer context
            for task in tasks {
                let combined = "\(task.title) \(task.description)"
                let words = combined
                    .split(separator: " ")
                    .filter { $0.count > 4 }
                    .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
                for word in words where word.first?.isUppercase == true {
                    topicDays[word, default: 0] += 1
                }
            }
        }

        var lines: [String] = []

        // Recurring projects from real project activity data (appeared 2+ days)
        let recurringProjects = projectDays.filter { $0.value >= 2 }.sorted { $0.value > $1.value }
        if !recurringProjects.isEmpty {
            let projects = recurringProjects.prefix(8).map { name, days in
                let mins = Int(projectMinutes[name] ?? 0)
                return "\(name) (\(days) days, \(mins)m total)"
            }.joined(separator: ", ")
            lines.append("Recurring projects this week: \(projects)")
        }

        // Supplementary recurring topics from task titles (things not captured by project activities)
        let projectNames = Set(projectDays.keys.map { $0.lowercased() })
        let recurringTopics = topicDays
            .filter { $0.value >= 2 && !projectNames.contains($0.key.lowercased()) }
            .sorted { $0.value > $1.value }
        if !recurringTopics.isEmpty {
            let topics = recurringTopics.prefix(6).map { "\($0.key) (\($0.value) days)" }.joined(separator: ", ")
            lines.append("Recurring themes: \(topics)")
        }

        // Daily active hours
        let sorted = dailyHours.sorted { $0.date < $1.date }
        if sorted.count >= 2 {
            let summary = sorted.map { "\($0.date): \(String(format: "%.1f", $0.hours))h" }.joined(separator: ", ")
            lines.append("Daily active hours: \(summary)")
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Build a compact activity log from the selected date's grouped activities,
    /// including window titles, browser URLs, and document paths.
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
            // Browser URLs visited in this group (deduplicated)
            let urls = group.activities
                .compactMap(\.browserURL)
                .filter { !$0.isEmpty }
                .reduce(into: [String]()) { result, url in
                    if !result.contains(url) { result.append(url) }
                }
            for url in urls.prefix(3) {
                lines.append("  → \(url)")
            }
            // Document paths opened in this group (deduplicated)
            let docs = group.activities
                .compactMap(\.documentPath)
                .filter { !$0.isEmpty }
                .reduce(into: [String]()) { result, doc in
                    if !result.contains(doc) { result.append(doc) }
                }
            for doc in docs.prefix(3) {
                lines.append("  📄 \(doc)")
            }
        }
        return lines.joined(separator: "\n")
    }

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

        // Load or build OCR digest for the target date
        var ocrDigest: String? = db.ocrDigest(for: date)
        if ocrDigest == nil {
            let ocrTexts = db.ocrTextsForDate(date)
            if !ocrTexts.isEmpty {
                let digest = OCRDigestBuilder.buildDigest(from: ocrTexts)
                if let section = digest.asPromptSection() {
                    db.insertOrReplaceOCRDigest(date: dateStr, digest: section)
                    ocrDigest = section
                }
            }
        }

        do {
            let content = try await generator.generateDaySummary(
                recentTasks: recentTasks,
                projectActivities: pas,
                appsUsed: appsUsed,
                memoryContext: memoryContext,
                activityLog: activityLog,
                weeklyTrends: nil,
                ocrDigest: ocrDigest,
                dateLabel: dateLabel
            )
            persistStubsContent(content, dateString: dateStr)
            Logger.info("Auto-generated day summary for \(dateStr)")
        } catch {
            Logger.error("Failed to auto-generate summary for \(dateStr): \(error.localizedDescription)")
        }
    }

    // MARK: - Error Formatting

    /// Convert errors into user-friendly messages for recommendations/stubs generation.
    private static func friendlyRecommendationsError(_ error: Error) -> String {
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
}

// MARK: - Timeout Helper

private struct TimeoutError: LocalizedError {
    let seconds: Int
    var errorDescription: String? { "Request timed out after \(seconds) seconds" }
}

/// Run an async operation with a timeout. Throws `TimeoutError` if the work doesn't complete in time.
private func withThrowingTimeout<T: Sendable>(
    seconds: Int,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError(seconds: seconds)
        }
        // The first task to complete wins; cancel the other
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return result
    }
}
