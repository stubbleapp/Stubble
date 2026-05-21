import Foundation
import TaskMinerShared

/// Generates AI-powered insights and next steps for a specific project (no product-style recommendations).
final class ProjectAnalysisGenerator: Sendable {
    private let geminiClient: GeminiClient

    init(geminiClient: GeminiClient) {
        self.geminiClient = geminiClient
    }

    /// Generate analysis for a specific project.
    func generate(
        project: AggregatedProject,
        memoryContext: String?,
        timePeriod: ProjectTimePeriod,
        synthesizedSummary: String? = nil
    ) async throws -> ProjectAnalysis {
        let effectiveSummary = synthesizedSummary ?? project.summary
        let prompt = buildPrompt(project: project, memoryContext: memoryContext, timePeriod: timePeriod, summary: effectiveSummary)

        let systemInstruction = """
        You are a knowledgeable assistant analyzing a user's work patterns on a specific project. \
        You know this user — their role, skills, and goals are provided in the User Profile section. \
        Use this context to make your analysis deeply relevant. \
        \
        Your output has two parts: \
        1. insights: 2-4 sentences analyzing work patterns, productivity, and notable observations \
           about THIS specific project. Reference concrete data (hours, apps, patterns). \
        2. next_steps: 2-3 concrete, actionable items the user could do TODAY or this week \
           based on observed patterns (not generic productivity tips). \
        \
        Rules: \
        - Be specific to THIS project — don't give generic advice \
        - Reference the actual work patterns (peak hours, apps used, consistency) \
        - Keep insights factual and grounded in the data provided \
        \
        Respond with a JSON object. Do not include any text outside the JSON.
        """

        for attempt in 0..<2 {
            do {
                let response = try await geminiClient.generateContent(
                    prompt: prompt,
                    systemInstruction: systemInstruction
                )

                if let analysis = parseResponse(response, projectName: project.name) {
                    return analysis
                }

                if attempt == 0 {
                    Logger.warning("ProjectAnalysisGenerator: parse failed (attempt 1), retrying")
                }
            } catch {
                if attempt == 1 { throw error }
                Logger.warning("ProjectAnalysisGenerator: API error (attempt 1): \(error.localizedDescription)")
            }
        }

        return ProjectAnalysis(
            projectName: project.name,
            generatedAt: Date(),
            insights: "Unable to generate insights at this time.",
            nextSteps: []
        )
    }

    // MARK: - Prompt Building

    private func buildPrompt(
        project: AggregatedProject,
        memoryContext: String?,
        timePeriod: ProjectTimePeriod,
        summary: String
    ) -> String {
        var lines: [String] = []

        if let memory = memoryContext, !memory.isEmpty {
            lines.append("## User Profile")
            lines.append(memory)
            lines.append("")
        }

        lines.append("## Project: \(project.name)")
        lines.append("")

        lines.append("### Summary")
        lines.append(summary.isEmpty ? "(No summary available)" : summary)
        lines.append("")

        lines.append("### Time Investment (\(timePeriod.displayName) view)")
        let totalHours = project.totalDuration / 3600
        let avgDailyMins = project.averageDailyDuration / 60
        lines.append("- Total time: \(String(format: "%.1f", totalHours)) hours")
        lines.append("- Days active: \(project.daysActive)")
        lines.append("- Average daily: \(Int(avgDailyMins)) minutes")
        lines.append("- Date range: \(formatDate(project.firstActiveDate)) – \(formatDate(project.lastActiveDate))")
        lines.append("")

        if !project.appNames.isEmpty {
            lines.append("### Apps Used")
            lines.append(project.appNames.sorted().joined(separator: ", "))
            lines.append("")
        }

        lines.append("### Work Patterns")

        if !project.peakHours.isEmpty {
            let peakHourLabels = project.peakHours.map { formatHour($0) }
            lines.append("- Peak hours: \(peakHourLabels.joined(separator: ", "))")
        }

        if !project.peakWeekdays.isEmpty {
            let weekdayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let peakDayLabels = project.peakWeekdays.compactMap { day -> String? in
                guard day >= 1 && day <= 7 else { return nil }
                return weekdayNames[day]
            }
            lines.append("- Peak days: \(peakDayLabels.joined(separator: ", "))")
        }

        let sortedDaily = project.dailyDurations.sorted { $0.key < $1.key }
        if sortedDaily.count > 1 {
            let durations = sortedDaily.map { $0.value / 60 }
            let max = durations.max() ?? 0
            let min = durations.min() ?? 0
            let variance = max - min
            if variance > 60 {
                lines.append("- High variance in daily time (range: \(Int(min))-\(Int(max)) min)")
            } else {
                lines.append("- Consistent daily time commitment")
            }
        }
        lines.append("")

        if !project.taskTitles.isEmpty {
            lines.append("### Recent Tasks")
            for title in project.taskTitles.prefix(10) {
                lines.append("- \(title)")
            }
            lines.append("")
        }

        lines.append("""
        ## Output Format
        Respond with a JSON object:
        {
          "insights": "2-4 sentences analyzing this project's work patterns...",
          "next_steps": [
            "Concrete actionable item 1",
            "Concrete actionable item 2"
          ]
        }
        """)

        return lines.joined(separator: "\n")
    }

    // MARK: - Response Parsing

    private func parseResponse(_ response: String, projectName: String) -> ProjectAnalysis? {
        guard let parsed = JSONSanitizer.parse(response) as? [String: Any] else {
            Logger.error("ProjectAnalysisGenerator: failed to parse JSON. Preview: \(String(response.prefix(300)))")
            return nil
        }

        let insights = parsed["insights"] as? String ?? ""
        let nextSteps = parsed["next_steps"] as? [String] ?? []

        return ProjectAnalysis(
            projectName: projectName,
            generatedAt: Date(),
            insights: insights,
            nextSteps: nextSteps
        )
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private func formatHour(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "am" : "pm"
        return "\(h)\(suffix)"
    }
}
