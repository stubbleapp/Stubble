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

    /// Generate stubs content: greeting, suggested questions, and recommendations.
    /// - Parameters:
    ///   - recentTasks: Tasks from the last few days, keyed by date string
    ///   - projectActivities: Current day's project activity clusters
    ///   - appsUsed: Map of app name → approximate total seconds used
    ///   - memoryContext: Known facts about the user from the memory store
    ///   - activityLog: Today's granular activity log (app sessions with window titles)
    /// - Returns: StubsContent with greeting, questions, and 2-5 recommendations
    func generate(
        recentTasks: [String: [TaskRecord]],
        projectActivities: [ProjectActivity],
        appsUsed: [String: TimeInterval],
        memoryContext: String?,
        activityLog: String? = nil
    ) async throws -> StubsContent {
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
        Your output has three parts: \
        1. greeting_context: A warm, casual 1-2 sentence summary of what the user has been working on recently, \
           ending with a natural transition like "here are some things that might help" or similar. \
           Reference specific projects, technologies, or tasks from the data. Keep it conversational. \
        2. suggested_questions: 3-4 thoughtful questions the user might want to ask an AI assistant \
           about their recent work. These should be specific to their actual activity — not generic. \
           Frame them as questions the user would ask (e.g. "How can I improve my test coverage for async code?"). \
        3. recommendations: 2-5 actionable recommendations (see categories below). \
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

            let content = parseResponse(response)
            if !content.recommendations.isEmpty || attempt == 1 {
                return content
            }

            Logger.warning("RecommendationGenerator: empty parse result (attempt \(attempt + 1)), retrying")
        }

        return StubsContent(greetingContext: "", daySummary: nil, suggestedQuestions: [], recommendations: [])
    }

    /// Generate a retrospective day summary for a past day.
    func generateDaySummary(
        recentTasks: [String: [TaskRecord]],
        projectActivities: [ProjectActivity],
        appsUsed: [String: TimeInterval],
        memoryContext: String?,
        activityLog: String? = nil,
        dateLabel: String
    ) async throws -> StubsContent {
        let prompt = buildPrompt(
            recentTasks: recentTasks,
            projectActivities: projectActivities,
            appsUsed: appsUsed,
            memoryContext: memoryContext,
            activityLog: activityLog
        )

        let systemInstruction = """
        You are a knowledgeable productivity assistant embedded in a desktop activity tracker called Stubble. \
        The user is reviewing a past day (\(dateLabel)). Provide a comprehensive retrospective analysis. \
        \
        Your output has four parts: \
        1. greeting_context: A warm, casual 1 sentence intro referencing the date and the main theme of the day \
           (e.g. "Last Tuesday was a big coding day" or "Wednesday was split between meetings and design work"). \
        2. day_summary: A comprehensive 2-4 paragraph narrative of what was done that day. Include: \
           - What the user worked on and how their time was split \
           - Notable patterns (e.g. "You spent most of the morning in deep focus on code, then switched to communications after lunch") \
           - Observations about work habits, context-switching, or focus blocks \
           - Any interesting trends (apps used, projects touched, time distribution) \
           Write in second person ("you"), warm and conversational. Use markdown for structure (bold, lists) where it helps. \
        3. suggested_questions: 3-4 thoughtful questions about that day's work \
           (e.g. "How could I have reduced the context-switching between projects?"). \
        4. recommendations: 1-3 brief takeaways or insights specific to that day. \
        \
        Rules: \
        - Be specific — reference actual tasks, apps, and projects from the data \
        - The day_summary should feel like a thoughtful end-of-day review \
        - Don't be generic — every observation should be rooted in the actual data \
        - If the data is sparse, keep the summary short and honest about it \
        \
        Respond with a JSON object. Do not include any text outside the JSON. \
        \
        JSON format: \
        { "greeting_context": "...", "day_summary": "...", "suggested_questions": [...], \
          "recommendations": [{"category": "...", "title": "...", "description": "...", \
          "reason": "...", "action_url": null, "icon": "..."}] }
        """

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

            let content = parseDaySummaryResponse(response)
            if content.daySummary != nil || attempt == 1 {
                return content
            }

            Logger.warning("RecommendationGenerator: empty day summary parse (attempt \(attempt + 1)), retrying")
        }

        return StubsContent(greetingContext: "", daySummary: nil, suggestedQuestions: [], recommendations: [])
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
          "greeting_context": "You've been deep into Swift concurrency and API integration lately — here are some things that might help.",
          "suggested_questions": [
            "What patterns should I follow for actor isolation in my codebase?",
            "How can I improve my test coverage for async code?",
            "What are the best practices for SQLite WAL mode on macOS?"
          ],
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

        Top-level fields:
        - greeting_context: 1-2 warm, casual sentences summarizing what the user has been working on, with a natural transition
        - suggested_questions: 3-4 specific questions the user might want to ask about their recent work

        Recommendation fields:
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

    private func parseResponse(_ response: String) -> StubsContent {
        guard let parsed = JSONSanitizer.parse(response) as? [String: Any],
              let items = parsed["recommendations"] as? [[String: Any]]
        else {
            Logger.error("RecommendationGenerator: failed to parse response. Preview: \(String(response.prefix(300)))")
            return StubsContent(greetingContext: "", daySummary: nil, suggestedQuestions: [], recommendations: [])
        }

        let greetingContext = parsed["greeting_context"] as? String ?? ""
        let suggestedQuestions = parsed["suggested_questions"] as? [String] ?? []

        let recommendations = items.compactMap { dict -> Recommendation? in
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

        return StubsContent(
            greetingContext: greetingContext,
            daySummary: nil,
            suggestedQuestions: suggestedQuestions,
            recommendations: recommendations
        )
    }

    private func parseDaySummaryResponse(_ response: String) -> StubsContent {
        guard let parsed = JSONSanitizer.parse(response) as? [String: Any] else {
            Logger.error("RecommendationGenerator: failed to parse day summary. Preview: \(String(response.prefix(300)))")
            return StubsContent(greetingContext: "", daySummary: nil, suggestedQuestions: [], recommendations: [])
        }

        let greetingContext = parsed["greeting_context"] as? String ?? ""
        let daySummary = parsed["day_summary"] as? String
        let suggestedQuestions = parsed["suggested_questions"] as? [String] ?? []

        let items = parsed["recommendations"] as? [[String: Any]] ?? []
        let recommendations = items.compactMap { dict -> Recommendation? in
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

        return StubsContent(
            greetingContext: greetingContext,
            daySummary: daySummary,
            suggestedQuestions: suggestedQuestions,
            recommendations: recommendations
        )
    }
}
