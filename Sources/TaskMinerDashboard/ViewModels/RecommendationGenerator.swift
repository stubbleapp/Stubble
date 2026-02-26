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
    func generate(
        recentTasks: [String: [TaskRecord]],
        projectActivities: [ProjectActivity],
        appsUsed: [String: TimeInterval],
        memoryContext: String?,
        activityLog: String? = nil,
        weeklyTrends: String? = nil,
        ocrDigest: String? = nil
    ) async throws -> StubsContent {
        let prompt = buildPrompt(
            recentTasks: recentTasks,
            projectActivities: projectActivities,
            appsUsed: appsUsed,
            memoryContext: memoryContext,
            activityLog: activityLog,
            weeklyTrends: weeklyTrends,
            ocrDigest: ocrDigest
        )

        let systemInstruction = """
        You are a knowledgeable assistant embedded in a desktop activity tracker called Stubble. \
        You know this user — their role, projects, goals, and working patterns are provided in the \
        User Profile section. USE THIS PROFILE to frame every recommendation around what matters \
        to THEM specifically. A recommendation for a Swift/macOS developer should be completely different \
        from one for a web developer, even if the activity looks similar. \
        \
        Your output has three parts: \
        1. greeting_context: A warm, personal 1-2 sentence contextual note that shows you know what they're \
           working on. Reference their specific projects or goals by name. \
           IMPORTANT: Do NOT include any greeting like "Hey", "Hi", "Hello", or the user's name — \
           the UI already displays a greeting header. Just jump straight into the context \
           (e.g. "You've been deep into the permission system this week..." not "Hey Sam, you've been..."). \
        2. suggested_questions: 3-4 SHORT questions (max 6-8 words each) the user might ask about their work. \
           Keep them punchy and concise — e.g. "Best WAL checkpoint strategy?", "Handle TCC after rebuild?". \
           Reference their actual projects and technologies but stay brief. \
        3. recommendations: 3-6 actionable items (see categories below). \
        \
        Categories: \
        - article: A relevant technical article, tutorial, or documentation page. MUST be a real, \
          existing URL from official docs, well-known blogs, or established resources. \
        - tool: A specific app, extension, CLI tool, or service. Explain HOW it helps their specific situation. \
        - best_practice: A concrete technique or methodology. Explain WHY it applies to their current work. \
        - workflow: A specific workflow improvement based on patterns you've observed across their week. \
        - learning: A skill or knowledge area that would accelerate their current projects. \
        \
        Rules: \
        - The User Profile is your primary lens. If the user is building a macOS app in Swift, recommend \
          Swift/macOS resources, not generic productivity tools. If they do legal work, recommend legal \
          tech and compliance resources. \
        - Cross-reference the weekly trends with the user profile to find the most impactful recommendations. \
          For example, if they've spent 3 days on a database layer, recommend specific database optimization \
          techniques for their stack. \
        - Use relevant links from tasks (repos, docs, file paths) to understand EXACTLY what projects and \
          codebases they're working in, then recommend resources specific to those. \
        - Every recommendation's "reason" must cite specific projects, tasks, or patterns from the data. \
        - Never recommend tools/apps the user already uses heavily. \
        - Prefer depth over breadth: 3 highly relevant recommendations beat 6 generic ones. \
        - URLs must be real and well-known — official docs, tool homepages, established tutorials. \
        - Avoid generic advice ("take breaks", "use version control", "back up your data"). \
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
        weeklyTrends: String? = nil,
        ocrDigest: String? = nil,
        dateLabel: String
    ) async throws -> StubsContent {
        let prompt = buildPrompt(
            recentTasks: recentTasks,
            projectActivities: projectActivities,
            appsUsed: appsUsed,
            memoryContext: memoryContext,
            activityLog: activityLog,
            weeklyTrends: weeklyTrends,
            ocrDigest: ocrDigest
        )

        let systemInstruction = """
        You are a knowledgeable assistant embedded in a desktop activity tracker called Stubble. \
        You know this user — their role, projects, and goals are in the User Profile section. \
        The user is reviewing a past day (\(dateLabel)). Provide a personalized retrospective. \
        \
        Your output has two parts: \
        1. greeting_context: A SHORT 1-sentence teaser (under 20 words) that sets up the date and main theme. \
           IMPORTANT: Do NOT include any greeting like "Hey", "Hi", "Hello", or the user's name — \
           the UI already displays a greeting header. Do NOT summarize the full day here — save details \
           for the day_summary. Just a brief hook, e.g. "A deep dive into the permission system and SQLite layer." \
        2. day_summary: A comprehensive 2-4 paragraph narrative. This is the main content — include ALL detail here: \
           - What the user worked on and how time was split, referencing project names from the profile \
           - Notable patterns (focus blocks, context-switching, deep work vs. communication) \
           - How this day's work fits into their broader goals and ongoing projects \
           - Any interesting observations about their habits or workflow \
           Write in second person ("you"), warm and conversational. Use markdown for structure. \
           Do NOT repeat the greeting_context — dive straight into the detail. \
        \
        Rules: \
        - Be specific — reference actual tasks, apps, and projects from the data \
        - Use the User Profile to add meaning beyond raw data (connect activities to goals) \
        - The day_summary should feel like a thoughtful, personalized end-of-day review \
        - Don't be generic — every observation should be rooted in the data and profile \
        - If the data is sparse, keep the summary short and honest about it \
        \
        Respond with a JSON object. Do not include any text outside the JSON. \
        \
        JSON format: \
        { "greeting_context": "...", "day_summary": "...", "suggested_questions": [], "recommendations": [] }
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
        activityLog: String?,
        weeklyTrends: String? = nil,
        ocrDigest: String? = nil
    ) -> String {
        var lines: [String] = []

        // User profile FIRST — this is the primary lens for personalization
        if let memory = memoryContext, !memory.isEmpty {
            lines.append("## User Profile")
            lines.append("This is what you know about this user. Use it to make every recommendation deeply relevant to their specific role, projects, and goals.")
            lines.append(memory)
            lines.append("")
        }

        // Weekly trends — cross-day patterns
        if let trends = weeklyTrends, !trends.isEmpty {
            lines.append("## Weekly Patterns")
            lines.append(trends)
            lines.append("")
        }

        lines.append("## Recent Activity Data")
        lines.append("")

        // Recent tasks by day — expanded detail with links
        let sortedDates = recentTasks.keys.sorted().reversed()
        for dateStr in sortedDates {
            guard let tasks = recentTasks[dateStr] else { continue }
            lines.append("### \(dateStr)")
            for task in tasks.prefix(15) {
                let durMins = Int(task.duration / 60)
                let apps = task.appNamesList.joined(separator: ", ")
                lines.append("- \"\(task.title)\" (\(durMins)m) — \(apps)")
                if !task.description.isEmpty {
                    lines.append("  \(task.description)")
                }
                let links = task.linksList.map(\.value)
                if !links.isEmpty {
                    lines.append("  Links: \(links.prefix(3).joined(separator: ", "))")
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

        // OCR-derived screen content analysis
        if let digest = ocrDigest, !digest.isEmpty {
            lines.append("## Screen Content Analysis (extracted from screenshots)")
            lines.append("This is what was actually visible on screen — URLs visited, code being written, documents open, communications:")
            lines.append(digest)
            lines.append("")
        }

        // Output format
        lines.append("""
        ## Output Format
        Respond with a JSON object:
        {
          "greeting_context": "Deep into the Stubble permission system and SQLite layer this week — here are some things that might help.",
          "suggested_questions": [
            "Handle TCC after rebuild?",
            "Best WAL checkpoint strategy?",
            "Cross-process memory on macOS?"
          ],
          "recommendations": [
            {
              "category": "article",
              "title": "Apple's TCC internals and code signing",
              "description": "Deep dive into how macOS TCC ties permissions to code signatures, and strategies for preserving them across updates — directly relevant to the permission issues you've been debugging in Stubble.",
              "reason": "You've spent multiple days this week working on TCC permission handling in Stubble",
              "action_url": "https://developer.apple.com/documentation/security/app_sandbox",
              "icon": "lock.shield"
            }
          ]
        }

        Top-level fields:
        - greeting_context: 1-2 warm, personal sentences (NO greeting/name — UI shows that) that reference the user's actual projects by name
        - suggested_questions: 3-4 SHORT questions (max 6-8 words each) tied to their current work

        Recommendation fields:
        - category: one of "article", "tool", "best_practice", "workflow", "learning"
        - title: concise, specific title that would only make sense for THIS user
        - description: 2-3 sentences explaining what this is and why it's valuable for THIS user's specific situation
        - reason: 1 sentence citing specific tasks, projects, or multi-day patterns from the data
        - action_url: a real URL (official docs, tool homepage, well-known tutorial). Use null if no URL applies.
        - icon: an SF Symbol name (e.g. "doc.text", "wrench.and.screwdriver", "lightbulb", "arrow.triangle.branch", "book", "cpu", "network", "lock.shield", "swift", "terminal")
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
