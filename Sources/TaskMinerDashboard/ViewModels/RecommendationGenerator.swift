import Foundation
import TaskMinerShared

/// Generates AI-powered recommendations based on the user's recent work activity.
/// Follows the same pattern as ProjectActivityGenerator — takes a GeminiClient,
/// builds a context-rich prompt, and parses structured JSON output.
final class RecommendationGenerator: Sendable {
    private let geminiClient: GeminiClient

    init(geminiClient: GeminiClient) {
        self.geminiClient = geminiClient
    }

    // MARK: - Public API

    /// Generate recommendations based on recent work context.
    /// - Parameters:
    ///   - recentTasks: Tasks from the last few days, keyed by date string
    ///   - projectActivities: Current day's project activity clusters
    ///   - appsUsed: Map of app name → approximate total seconds used
    ///   - memoryContext: Known facts about the user from the memory store
    ///   - activityLog: Today's granular activity log (app sessions with window titles)
    /// - Returns: Array of 2-5 recommendations
    func generate(
        recentTasks: [String: [TaskRecord]],
        projectActivities: [ProjectActivity],
        appsUsed: [String: TimeInterval],
        memoryContext: String?,
        activityLog: String? = nil
    ) async throws -> [Recommendation] {
        let prompt = buildPrompt(
            recentTasks: recentTasks,
            projectActivities: projectActivities,
            appsUsed: appsUsed,
            memoryContext: memoryContext,
            activityLog: activityLog
        )

        let systemInstruction = """
        You are a knowledgeable productivity assistant embedded in a desktop activity tracker called Stubble. \
        You provide highly specific, actionable recommendations based on a user's ACTUAL recent \
        computer activity. Every recommendation MUST directly relate to something the user worked on. \
        Never give generic productivity advice that could apply to anyone. \
        \
        Categories: \
        - article: A relevant technical article, tutorial, or documentation page \
        - tool: A specific app, extension, CLI tool, or service that would help their workflow \
        - best_practice: A concrete technique or methodology relevant to their current work \
        - workflow: A specific workflow improvement based on observed patterns \
        \
        Rules: \
        - Produce between 2 and 5 recommendations (fewer is better if quality is higher) \
        - Each MUST reference specific work the user actually did in the data provided \
        - Use window titles and activity details to understand WHAT the user was actually doing, not just which app \
        - URLs must be real, well-known, and relevant (official docs, popular tutorials, tool homepages) \
        - The "reason" field must cite specific tasks, projects, or apps from the data \
        - Never recommend apps the user already uses heavily (check the apps list) \
        - Focus on the most recent activity for freshness \
        - Prefer recommendations that: deepen expertise on topics they're actively working on, \
          introduce tools that solve problems they appear to be facing, or suggest best practices \
          for technologies they're using \
        - Avoid obvious or generic suggestions like "use a password manager" or "take breaks" \
        \
        Respond with a JSON object. Do not include any text outside the JSON.
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

            let recommendations = parseResponse(response)
            if !recommendations.isEmpty || attempt == 1 {
                return recommendations
            }

            Logger.warning("RecommendationGenerator: empty parse result (attempt \(attempt + 1)), retrying")
        }

        return []
    }

    // MARK: - Prompt Building

    private func buildPrompt(
        recentTasks: [String: [TaskRecord]],
        projectActivities: [ProjectActivity],
        appsUsed: [String: TimeInterval],
        memoryContext: String?,
        activityLog: String?
    ) -> String {
        var lines: [String] = []

        lines.append("Based on the following recent computer activity, provide personalized recommendations.")
        lines.append("")

        // Recent tasks by day
        let sortedDates = recentTasks.keys.sorted().reversed()
        for dateStr in sortedDates.prefix(3) {
            guard let tasks = recentTasks[dateStr] else { continue }
            lines.append("## Tasks on \(dateStr)")
            for task in tasks.prefix(10) {
                let durMins = Int(task.duration / 60)
                let apps = task.appNamesList.joined(separator: ", ")
                lines.append("- \"\(task.title)\" (\(durMins)m) — \(apps)")
                if !task.description.isEmpty {
                    lines.append("  \(task.description)")
                }
            }
            lines.append("")
        }

        // Project activities (higher-level grouping)
        if !projectActivities.isEmpty {
            lines.append("## Current Project Activities")
            for activity in projectActivities {
                let durMins = Int(activity.totalDuration / 60)
                lines.append("- \(activity.name) (\(durMins)m): \(activity.summary)")
                if !activity.appNames.isEmpty {
                    lines.append("  Apps: \(activity.appNames.joined(separator: ", "))")
                }
            }
            lines.append("")
        }

        // Apps and time spent
        if !appsUsed.isEmpty {
            lines.append("## Apps Used (sorted by time)")
            let sorted = appsUsed.sorted { $0.value > $1.value }
            for (app, seconds) in sorted.prefix(15) {
                let mins = Int(seconds / 60)
                if mins > 0 {
                    lines.append("- \(app): \(mins)m")
                }
            }
            lines.append("")
        }

        // Detailed activity log — window titles reveal specific documents, URLs, and content
        if let log = activityLog, !log.isEmpty {
            lines.append("## Today's Detailed Activity (window titles)")
            lines.append(log)
            lines.append("")
        }

        // Memory context
        if let memory = memoryContext, !memory.isEmpty {
            lines.append("## Known Context About This User")
            lines.append(memory)
            lines.append("")
        }

        // Output format
        lines.append("""
        ## Output Format
        Respond with a JSON object:
        {
          "recommendations": [
            {
              "category": "article",
              "title": "Understanding Swift Concurrency with async/await",
              "description": "A comprehensive guide to structured concurrency in Swift, covering Task groups, actors, and Sendable conformance — directly relevant to the concurrent code patterns observed in your recent work.",
              "reason": "You spent significant time working on async code in your Stubble project",
              "action_url": "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/",
              "icon": "doc.text"
            }
          ]
        }

        Fields:
        - category: one of "article", "tool", "best_practice", "workflow"
        - title: concise, specific title (not generic)
        - description: 2-3 sentences explaining what this is and why it's valuable for THIS user
        - reason: 1 sentence citing specific tasks/projects/apps from the data above
        - action_url: a real URL (official docs, tool homepage, well-known tutorial). Use null if no URL applies.
        - icon: an SF Symbol name that fits the recommendation (e.g. "doc.text", "wrench.and.screwdriver", "lightbulb", "arrow.triangle.branch", "book", "cpu", "network")
        """)

        return lines.joined(separator: "\n")
    }

    // MARK: - Response Parsing

    private func parseResponse(_ response: String) -> [Recommendation] {
        guard let parsed = JSONSanitizer.parse(response) as? [String: Any],
              let items = parsed["recommendations"] as? [[String: Any]]
        else {
            Logger.error("RecommendationGenerator: failed to parse response. Preview: \(String(response.prefix(300)))")
            return []
        }

        return items.compactMap { dict -> Recommendation? in
            guard let categoryStr = dict["category"] as? String,
                  let title = dict["title"] as? String,
                  let description = dict["description"] as? String,
                  let reason = dict["reason"] as? String
            else { return nil }

            let category = Recommendation.Category(rawValue: categoryStr) ?? .bestPractice
            let actionURL = dict["action_url"] as? String
            let iconName = dict["icon"] as? String ?? category.defaultIcon

            return Recommendation(
                id: UUID(),
                category: category,
                title: title,
                description: description,
                reason: reason,
                actionLabel: actionURL != nil ? category.defaultActionLabel : "Noted",
                actionURL: actionURL,
                iconName: iconName
            )
        }
    }
}
