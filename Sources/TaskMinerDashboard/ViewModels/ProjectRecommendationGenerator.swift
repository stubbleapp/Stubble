import Foundation
import TaskMinerShared

/// Generates AI-powered analysis and recommendations for a specific project.
final class ProjectRecommendationGenerator: Sendable {
    private let geminiClient: GeminiClient

    init(geminiClient: GeminiClient) {
        self.geminiClient = geminiClient
    }

    // MARK: - Public API

    /// Generate analysis and recommendations for a specific project.
    func generate(
        project: AggregatedProject,
        memoryContext: String?,
        timePeriod: ProjectTimePeriod
    ) async throws -> ProjectAnalysis {
        let prompt = buildPrompt(project: project, memoryContext: memoryContext, timePeriod: timePeriod)

        let systemInstruction = """
        You are a knowledgeable assistant analyzing a user's work patterns on a specific project. \
        You know this user — their role, skills, and goals are provided in the User Profile section. \
        Use this context to make your analysis and recommendations deeply relevant. \
        \
        Your output has three parts: \
        1. insights: 2-3 sentences analyzing work patterns, productivity, and notable observations \
           about THIS specific project. Reference concrete data (hours, apps, patterns). \
        2. recommendations: 3-4 recommendations to improve productivity or quality for THIS project. \
           Each should be actionable and specific to the observed work patterns. \
        3. next_steps: 2-3 concrete, actionable items the user could do TODAY or this week. \
        \
        Categories for recommendations: \
        - article: A relevant technical article, tutorial, or documentation \
        - tool: A specific app, extension, CLI tool, or service \
        - best_practice: A concrete technique or methodology \
        - workflow: A workflow improvement based on observed patterns \
        - learning: A skill or knowledge area for this project \
        \
        Rules: \
        - Be specific to THIS project — don't give generic advice \
        - Reference the actual work patterns (peak hours, apps used, consistency) \
        - URLs: Only use URLs you're certain exist. Use null if uncertain. \
        - Keep insights concise but data-driven \
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
                    Logger.warning("ProjectRecommendationGenerator: parse failed (attempt 1), retrying")
                }
            } catch {
                if attempt == 1 { throw error }
                Logger.warning("ProjectRecommendationGenerator: API error (attempt 1): \(error.localizedDescription)")
            }
        }

        // Fallback if all attempts fail
        return ProjectAnalysis(
            projectName: project.name,
            generatedAt: Date(),
            insights: "Unable to generate insights at this time.",
            recommendations: [],
            nextSteps: []
        )
    }

    // MARK: - Prompt Building

    private func buildPrompt(
        project: AggregatedProject,
        memoryContext: String?,
        timePeriod: ProjectTimePeriod
    ) -> String {
        var lines: [String] = []

        // User profile
        if let memory = memoryContext, !memory.isEmpty {
            lines.append("## User Profile")
            lines.append(memory)
            lines.append("")
        }

        // Project details
        lines.append("## Project: \(project.name)")
        lines.append("")

        lines.append("### Summary")
        lines.append(project.summary.isEmpty ? "(No summary available)" : project.summary)
        lines.append("")

        // Time metrics
        lines.append("### Time Investment (\(timePeriod.displayName) view)")
        let totalHours = project.totalDuration / 3600
        let avgDailyMins = project.averageDailyDuration / 60
        lines.append("- Total time: \(String(format: "%.1f", totalHours)) hours")
        lines.append("- Days active: \(project.daysActive)")
        lines.append("- Average daily: \(Int(avgDailyMins)) minutes")
        lines.append("- Date range: \(formatDate(project.firstActiveDate)) – \(formatDate(project.lastActiveDate))")
        lines.append("")

        // Apps used
        if !project.appNames.isEmpty {
            lines.append("### Apps Used")
            lines.append(project.appNames.sorted().joined(separator: ", "))
            lines.append("")
        }

        // Work patterns
        lines.append("### Work Patterns")

        // Peak hours
        if !project.peakHours.isEmpty {
            let peakHourLabels = project.peakHours.map { formatHour($0) }
            lines.append("- Peak hours: \(peakHourLabels.joined(separator: ", "))")
        }

        // Peak weekdays
        if !project.peakWeekdays.isEmpty {
            let weekdayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let peakDayLabels = project.peakWeekdays.compactMap { day -> String? in
                guard day >= 1 && day <= 7 else { return nil }
                return weekdayNames[day]
            }
            lines.append("- Peak days: \(peakDayLabels.joined(separator: ", "))")
        }

        // Daily consistency
        let sortedDaily = project.dailyDurations.sorted { $0.key < $1.key }
        if sortedDaily.count > 1 {
            let durations = sortedDaily.map { $0.value / 60 } // minutes
            let max = durations.max() ?? 0
            let min = durations.min() ?? 0
            let variance = max - min
            if variance > 60 { // More than 1 hour variance
                lines.append("- High variance in daily time (range: \(Int(min))-\(Int(max)) min)")
            } else {
                lines.append("- Consistent daily time commitment")
            }
        }
        lines.append("")

        // Recent tasks
        if !project.taskTitles.isEmpty {
            lines.append("### Recent Tasks")
            for title in project.taskTitles.prefix(10) {
                lines.append("- \(title)")
            }
            lines.append("")
        }

        // Output format
        lines.append("""
        ## Output Format
        Respond with a JSON object:
        {
          "insights": "2-3 sentences analyzing this project's work patterns...",
          "recommendations": [
            {
              "category": "tool",
              "title": "Specific recommendation title",
              "description": "Why this helps and how to use it",
              "reason": "Based on observed patterns...",
              "action_url": "https://example.com" or null,
              "icon": "wrench.and.screwdriver"
            }
          ],
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
            Logger.error("ProjectRecommendationGenerator: failed to parse JSON. Preview: \(String(response.prefix(300)))")
            return nil
        }

        let insights = parsed["insights"] as? String ?? ""
        let nextSteps = parsed["next_steps"] as? [String] ?? []

        let recommendationDicts = parsed["recommendations"] as? [[String: Any]] ?? []
        let recommendations = recommendationDicts.compactMap { dict -> ProjectRecommendation? in
            guard let category = dict["category"] as? String,
                  let title = dict["title"] as? String,
                  let description = dict["description"] as? String,
                  let reason = dict["reason"] as? String
            else { return nil }

            return ProjectRecommendation(
                id: UUID(),
                category: category,
                title: title,
                description: description,
                reason: reason,
                actionURL: dict["action_url"] as? String,
                iconName: dict["icon"] as? String ?? ""
            )
        }

        return ProjectAnalysis(
            projectName: projectName,
            generatedAt: Date(),
            insights: insights,
            recommendations: recommendations,
            nextSteps: nextSteps
        )
    }

    // MARK: - Formatting Helpers

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
