import Foundation
import TaskMinerShared

/// Generates AI-powered habits analysis based on aggregated cross-day data.
/// Follows the same pattern as RecommendationGenerator — builds a prompt,
/// sends to Gemini, parses structured JSON output.
final class HabitsGenerator: Sendable {
    private let geminiClient: GeminiClient

    init(geminiClient: GeminiClient) {
        self.geminiClient = geminiClient
    }

    // MARK: - Public API

    func generate(
        snapshot: HabitsDataSnapshot,
        memoryContext: String?,
        ocrDigest: String?
    ) async throws -> HabitsAnalysis {
        let prompt = buildPrompt(snapshot: snapshot, memoryContext: memoryContext, ocrDigest: ocrDigest)

        let systemInstruction = """
        You are an assistant embedded in a desktop activity tracker called Stubble. You are analyzing \
        long-term work patterns across \(snapshot.totalDaysAnalyzed) days of captured data. \
        \
        The User Profile tells you who this person is — their role, projects, goals, and tools. \
        USE THIS PROFILE to make every insight specific and personal. A developer's "context switching" \
        means something completely different than a designer's. \
        \
        Your job: \
        1. Identify 4-8 habit patterns from the data. Each MUST cite a specific number from the stats. \
        2. Frame habits positively where possible — "Strong morning focus blocks" rather than just \
           "You switch apps too much in the afternoon." Acknowledge strengths, then note areas for improvement. \
        3. Detect trends by comparing recent weeks to the overall average when the data supports it. \
        4. Generate 3-6 improvement suggestions. Each must be SPECIFIC and ACTIONABLE — not generic. \
           "Timebox email to two 20-minute windows at 10am and 3pm" beats "Reduce email time." \
        5. Never recommend tools the user already uses heavily (check the top apps list). \
        6. Compare the user to THEMSELVES over time, never to others or "ideal" benchmarks. \
        \
        Categories for habits: focus, energy, communication, breaks, projects, work_life \
        Categories for improvements: same set \
        \
        Respond with a JSON object only. No text outside the JSON.
        """

        // Attempt up to 2 times — retry once if JSON parsing fails
        for attempt in 0..<2 {
            let response: String
            do {
                response = try await geminiClient.generateContent(
                    prompt: prompt,
                    systemInstruction: systemInstruction
                )
            } catch {
                throw error
            }

            if let analysis = parseResponse(response, daysAnalyzed: snapshot.totalDaysAnalyzed) {
                if !analysis.habits.isEmpty || attempt == 1 {
                    return analysis
                }
            }

            Logger.warning("HabitsGenerator: empty parse result (attempt \(attempt + 1)), retrying")
        }

        // Fallback empty result
        return HabitsAnalysis(
            generatedAt: Date(),
            daysAnalyzed: snapshot.totalDaysAnalyzed,
            summary: "",
            habits: [],
            improvements: []
        )
    }

    // MARK: - Prompt Building

    private func buildPrompt(
        snapshot: HabitsDataSnapshot,
        memoryContext: String?,
        ocrDigest: String?
    ) -> String {
        var lines: [String] = []

        // User profile FIRST
        if let memory = memoryContext, !memory.isEmpty {
            lines.append("## User Profile")
            lines.append("Use this to personalize every insight to their specific role, projects, and goals.")
            lines.append(memory)
            lines.append("")
        }

        lines.append("## Activity Data Summary (\(snapshot.totalDaysAnalyzed) days, \(SharedFormatters.shortDateFormatter.string(from: snapshot.earliestDate)) – \(SharedFormatters.shortDateFormatter.string(from: snapshot.latestDate)))")
        lines.append("")

        // Focus & Context Switching
        lines.append("### Focus & Context Switching")
        lines.append("- Average app switches per active hour: \(String(format: "%.1f", snapshot.avgAppSwitchesPerHour))")
        lines.append("- Average focus duration before switching: \(String(format: "%.1f", snapshot.avgFocusDurationMinutes))min")
        lines.append("- Deep work ratio (blocks > 25min): \(String(format: "%.0f", snapshot.deepWorkRatio * 100))%")
        lines.append("- Average deep work block length: \(String(format: "%.0f", snapshot.avgDeepWorkBlockMinutes))min")
        lines.append("")

        // Energy & Productivity Curve
        lines.append("### Energy & Productivity Curve (avg active minutes per hour)")
        let sortedHours = snapshot.hourlyProductivity.sorted { $0.key < $1.key }
        for (hour, mins) in sortedHours where mins > 0.1 {
            let label = hour < 12 ? "\(hour)am" : (hour == 12 ? "12pm" : "\(hour - 12)pm")
            lines.append("- \(label): \(String(format: "%.1f", mins))min")
        }
        lines.append("")

        // Break Patterns
        lines.append("### Break Patterns")
        lines.append("- Average breaks per active hour: \(String(format: "%.2f", snapshot.avgBreakFrequencyPerHour))")
        lines.append("- Average break duration: \(String(format: "%.1f", snapshot.avgBreakDurationMinutes))min")
        lines.append("")

        // App Usage
        lines.append("### App Usage (top \(min(snapshot.topApps.count, 10)))")
        for app in snapshot.topApps.prefix(10) {
            lines.append("- \(app.name): \(String(format: "%.0f", app.totalMinutes))min total, \(String(format: "%.1f", app.avgDailyMinutes))min/day avg")
        }
        lines.append("- Communication app time: \(String(format: "%.0f", snapshot.communicationTimeRatio * 100))%")
        lines.append("")

        // Project Patterns
        lines.append("### Project Patterns")
        lines.append("- Average active projects per day: \(String(format: "%.1f", snapshot.avgActiveProjectsPerDay))")
        if !snapshot.projectConsistency.isEmpty {
            lines.append("- Most consistent projects:")
            for proj in snapshot.projectConsistency.prefix(5) {
                lines.append("  - \(proj.name): \(proj.daysActive) days active, \(String(format: "%.0f", proj.avgDailyMinutes))min/day avg")
            }
        }
        lines.append("")

        // Work Hours
        lines.append("### Work Hours")
        lines.append("- Typical start: \(formatHour(snapshot.avgStartHour))")
        lines.append("- Typical end: \(formatHour(snapshot.avgEndHour))")
        lines.append("- Average daily active hours: \(String(format: "%.1f", snapshot.avgDailyActiveHours))")
        lines.append("")

        // Weekly Trend
        if !snapshot.weeklyActiveHours.isEmpty {
            lines.append("### Weekly Trend (recent weeks)")
            for week in snapshot.weeklyActiveHours {
                lines.append("- Week of \(week.weekLabel): \(String(format: "%.1f", week.hours))h")
            }
            lines.append("")
        }

        // OCR digest
        if let digest = ocrDigest, !digest.isEmpty {
            lines.append("### Screen Content Patterns (from OCR)")
            lines.append(digest)
            lines.append("")
        }

        // Output format
        lines.append("""
        ## Output Format
        Respond with a JSON object:
        {
          "summary": "A 2-3 sentence overview of the user's key work patterns and notable strengths or areas for growth.",
          "habits": [
            {
              "category": "focus",
              "title": "Strong Morning Deep Work",
              "description": "Your most productive coding happens between 9-11am, with average focus blocks of 35 minutes — well above your afternoon average of 12 minutes.",
              "data_point": "35min avg morning focus blocks",
              "trend": "stable",
              "icon": "brain.head.profile"
            }
          ],
          "improvements": [
            {
              "category": "communication",
              "title": "Batch Slack to Three 15-Minute Windows",
              "description": "You currently check Slack an average of 18 times per day across scattered intervals. Try batching to 10am, 1pm, and 4pm — this could free up an estimated 40 minutes of focus time daily.",
              "impact": "high",
              "related_habit": "Fragmented Communication",
              "icon": "bubble.left.and.bubble.right"
            }
          ]
        }

        Habit fields:
        - category: one of "focus", "energy", "communication", "breaks", "projects", "work_life"
        - title: concise, specific to THIS user's patterns
        - description: 2-3 sentences with specific numbers from the data
        - data_point: the key metric (e.g. "12 switches/hr", "35min avg focus")
        - trend: "improving", "declining", or "stable" (or null if not enough data)
        - icon: SF Symbol name

        Improvement fields:
        - category: same as above
        - title: specific, actionable (include numbers where possible)
        - description: 2-3 sentences explaining the suggestion and expected impact
        - impact: "high", "medium", or "low"
        - related_habit: title of a related habit insight (or null)
        - icon: SF Symbol name
        """)

        return lines.joined(separator: "\n")
    }

    // MARK: - Response Parsing

    private func parseResponse(_ response: String, daysAnalyzed: Int) -> HabitsAnalysis? {
        guard let parsed = JSONSanitizer.parse(response) as? [String: Any] else {
            Logger.error("HabitsGenerator: failed to parse response. Preview: \(String(response.prefix(300)))")
            return nil
        }

        let summary = parsed["summary"] as? String ?? ""

        let habitsArray = parsed["habits"] as? [[String: Any]] ?? []
        let habits: [HabitInsight] = habitsArray.compactMap { dict in
            guard let categoryStr = dict["category"] as? String,
                  let title = dict["title"] as? String,
                  let description = dict["description"] as? String,
                  let dataPoint = dict["data_point"] as? String
            else { return nil }

            let category = HabitCategory(rawValue: categoryStr) ?? .focus
            let trendStr = dict["trend"] as? String
            let trend = trendStr.flatMap { HabitInsight.Trend(rawValue: $0) }
            let iconName = dict["icon"] as? String ?? category.defaultIcon

            return HabitInsight(
                id: UUID(),
                category: category,
                title: title,
                description: description,
                dataPoint: dataPoint,
                trend: trend,
                iconName: iconName
            )
        }

        let improvementsArray = parsed["improvements"] as? [[String: Any]] ?? []
        let improvements: [ImprovementSuggestion] = improvementsArray.compactMap { dict in
            guard let categoryStr = dict["category"] as? String,
                  let title = dict["title"] as? String,
                  let description = dict["description"] as? String,
                  let impactStr = dict["impact"] as? String
            else { return nil }

            let category = HabitCategory(rawValue: categoryStr) ?? .focus
            let impact = ImprovementSuggestion.Impact(rawValue: impactStr) ?? .medium
            let relatedHabit = dict["related_habit"] as? String
            let iconName = dict["icon"] as? String ?? category.defaultIcon

            return ImprovementSuggestion(
                id: UUID(),
                category: category,
                title: title,
                description: description,
                impact: impact,
                relatedHabit: relatedHabit,
                iconName: iconName
            )
        }

        return HabitsAnalysis(
            generatedAt: Date(),
            daysAnalyzed: daysAnalyzed,
            summary: summary,
            habits: habits,
            improvements: improvements
        )
    }

    // MARK: - Helpers

    private func formatHour(_ h: Double) -> String {
        let hour = Int(h)
        let minute = Int((h - Double(hour)) * 60)
        let period = hour < 12 ? "am" : "pm"
        let displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        return minute > 0 ? "\(displayHour):\(String(format: "%02d", minute))\(period)" : "\(displayHour)\(period)"
    }
}
