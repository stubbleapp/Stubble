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
    /// Uses two-stage generation: first generates candidates, then refines for relevance.
    func generate(
        recentTasks: [String: [TaskRecord]],
        projectActivities: [ProjectActivity],
        appsUsed: [String: TimeInterval],
        memoryContext: String?,
        activityLog: String? = nil,
        weeklyTrends: String? = nil,
        ocrDigest: String? = nil
    ) async throws -> StubsContent {
        // Stage 1: Generate candidate recommendations (6-8 items)
        let candidateContent = try await generateCandidates(
            recentTasks: recentTasks,
            projectActivities: projectActivities,
            appsUsed: appsUsed,
            memoryContext: memoryContext,
            activityLog: activityLog,
            weeklyTrends: weeklyTrends,
            ocrDigest: ocrDigest
        )

        // If we got few recommendations, skip refinement
        guard candidateContent.recommendations.count > 3 else {
            return candidateContent
        }

        // Stage 2: Refine recommendations for relevance
        let refinedRecs = try await refineRecommendations(
            candidates: candidateContent.recommendations,
            memoryContext: memoryContext,
            primaryFocus: extractPrimaryFocus(from: recentTasks, projectActivities: projectActivities)
        )

        return StubsContent(
            greetingContext: candidateContent.greetingContext,
            daySummary: nil,
            suggestedQuestions: candidateContent.suggestedQuestions,
            recommendations: refinedRecs
        )
    }

    /// Generate only suggested questions (lightweight call for refreshing just the prompts).
    func generateSuggestedQuestions(
        recentTasks: [String: [TaskRecord]],
        projectActivities: [ProjectActivity],
        memoryContext: String?
    ) async throws -> [String] {
        let prompt = buildSuggestedQuestionsPrompt(
            recentTasks: recentTasks,
            projectActivities: projectActivities,
            memoryContext: memoryContext
        )

        let systemInstruction = """
        You are a helpful assistant generating conversation starters based on a user's recent work. \
        Generate 4-5 short prompts (max 8 words each) that the user might want to ask about their work. \
        Mix questions ("Best approach for X?") and action requests ("Help me debug Y", "Explain Z"). \
        At least one should be exploratory or interest-driven. \
        Respond with a JSON object: { "questions": ["...", "...", ...] }
        """

        let response = try await geminiClient.generateContent(
            prompt: prompt,
            systemInstruction: systemInstruction
        )

        return parseSuggestedQuestionsResponse(response)
    }

    private func buildSuggestedQuestionsPrompt(
        recentTasks: [String: [TaskRecord]],
        projectActivities: [ProjectActivity],
        memoryContext: String?
    ) -> String {
        var lines: [String] = []

        // User context
        if let memory = memoryContext, !memory.isEmpty {
            lines.append("## User Profile")
            lines.append(memory)
            lines.append("")
        }

        // Today's tasks (primary focus)
        let todayStr = SharedFormatters.dayFormatter.string(from: Date())
        if let todayTasks = recentTasks[todayStr], !todayTasks.isEmpty {
            lines.append("## Today's Work")
            for task in todayTasks.prefix(10) {
                let duration = Int(task.duration / 60)
                lines.append("- \(task.title) (\(duration)m)")
            }
            lines.append("")
        }

        // Current projects
        if !projectActivities.isEmpty {
            lines.append("## Active Projects")
            for pa in projectActivities.prefix(5) {
                lines.append("- \(pa.name)")
            }
            lines.append("")
        }

        lines.append("Generate 4-5 short prompts the user might ask about their work today.")

        return lines.joined(separator: "\n")
    }

    private func parseSuggestedQuestionsResponse(_ response: String) -> [String] {
        guard let parsed = JSONSanitizer.parse(response) as? [String: Any],
              let questions = parsed["questions"] as? [String]
        else {
            Logger.error("RecommendationGenerator: failed to parse suggested questions. Preview: \(String(response.prefix(200)))")
            return []
        }
        return questions
    }

    // MARK: - Two-Stage Generation

    /// Stage 1: Generate 6-8 candidate recommendations with full context.
    private func generateCandidates(
        recentTasks: [String: [TaskRecord]],
        projectActivities: [ProjectActivity],
        appsUsed: [String: TimeInterval],
        memoryContext: String?,
        activityLog: String?,
        weeklyTrends: String?,
        ocrDigest: String?
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
        You know this user — their role, projects, goals, working patterns, and interests are provided \
        in the User Profile section. USE THIS PROFILE to frame every recommendation around what matters \
        to THEM specifically. A recommendation for a Swift/macOS developer should be completely different \
        from one for a web developer, even if the activity looks similar. \
        \
        IMPORTANT: Pay close attention to the RECENCY TIERS in the activity data. Today and yesterday \
        show full detail because that's what the user is actively working on RIGHT NOW. Older data \
        shows summaries for context. Prioritize recommendations that help with TODAY'S work. \
        \
        Your output has three parts: \
        1. greeting_context: A warm, personal 1-2 sentence contextual note that shows you know what they're \
           working on RIGHT NOW. Reference their specific projects or goals by name. \
           IMPORTANT: Do NOT include any greeting like "Hey", "Hi", "Hello", or the user's name — \
           the UI already displays a greeting header. Just jump straight into the context \
           (e.g. "You've been deep into the permission system this week..." not "Hey Sam, you've been..."). \
        2. suggested_questions: 3-4 SHORT prompts (max 6-8 words each) the user might send about their \
           CURRENT work, interests, or areas of curiosity. These can be questions OR action requests. \
           Mix it up — include both question-style ("Best WAL checkpoint strategy?") and ask-style \
           ("Help me optimize the SQLite queries", "Explain the TCC permission model"). \
           At least one should be exploratory or interest-driven. Keep them punchy and concise. \
           Reference their actual projects, technologies, and interests but stay brief. \
        3. recommendations: Generate 6-8 candidate recommendations (see categories below). \
           These will be refined in a second pass, so include a mix of categories and depths. \
        \
        Categories: \
        - article: A relevant technical article, tutorial, or documentation page. \
        - tool: A specific app, extension, CLI tool, or service. Explain HOW it helps their specific situation. \
        - best_practice: A concrete technique or methodology. Explain WHY it applies to their current work. \
        - workflow: A specific workflow improvement based on patterns you've observed across their week. \
        - learning: A skill or knowledge area that would accelerate their current projects. \
        - exploration: A resource, community, or topic that connects to the user's interests or curiosity \
          areas beyond their daily tasks. Could be a conference talk, research paper, podcast, community, \
          or side-project idea. Use this when you spot something that bridges their work and interests. \
        \
        Rules: \
        - The User Profile is your primary lens. If the user is building a macOS app in Swift, recommend \
          Swift/macOS resources, not generic productivity tools. \
        - PRIORITIZE TODAY'S WORK: The most relevant recommendations address what the user is doing RIGHT NOW. \
        - Cross-reference the weekly trends with the user profile to find the most impactful recommendations. \
        - Use the browser URLs and document paths to understand EXACTLY what pages they're reading and \
          what files they're editing — then recommend resources that go deeper on those specific topics. \
        - Every recommendation's "reason" must cite specific projects, tasks, or patterns from the data. \
        - Never recommend tools/apps the user already uses heavily. \
        - URLs: ONLY use homepage or landing page URLs that you are CERTAIN exist. Examples: \
          "https://developer.apple.com/documentation/security" (not deep subpages), \
          "https://www.sqlite.org/wal.html", "https://github.com/user/repo" (real repos only). \
          If you're not 100% certain a URL exists, use null instead. Better no link than a 404. \
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

    /// Stage 2: Refine candidates by scoring for relevance and filtering to top 3-4.
    private func refineRecommendations(
        candidates: [Recommendation],
        memoryContext: String?,
        primaryFocus: String
    ) async throws -> [Recommendation] {
        // Build a compact representation of candidates for the refinement prompt
        var candidateLines: [String] = []
        for (index, rec) in candidates.enumerated() {
            candidateLines.append("""
            [\(index)] \(rec.category.rawValue): "\(rec.title)"
               Description: \(rec.description)
               Reason: \(rec.reason)
            """)
        }

        let refinementPrompt = """
        ## User Context
        \(memoryContext ?? "No profile available")

        ## Current Primary Focus
        \(primaryFocus)

        ## Candidate Recommendations
        \(candidateLines.joined(separator: "\n\n"))

        ## Task
        Score each recommendation on a scale of 1-5 for:
        1. RELEVANCE: Does this directly help with their PRIMARY focus (not tangential projects)?
        2. ACTIONABILITY: Can they use this TODAY, not someday?
        3. NOVELTY: Is this something they likely DON'T already know?

        Select the TOP 3-4 recommendations that score highest overall (minimum 3 on relevance).
        Return ONLY the indices of the selected recommendations, in order of relevance.

        Respond with JSON: {"selected_indices": [0, 2, 5]}
        """

        let systemInstruction = """
        You are a recommendation quality filter. Your job is to select the most relevant, \
        actionable, and novel recommendations from a candidate list. \
        Be ruthless — only keep recommendations that DIRECTLY help with the user's current work. \
        Discard anything generic, tangential, or that the user likely already knows. \
        Respond with ONLY a JSON object containing the selected indices.
        """

        do {
            let response = try await geminiClient.generateContent(
                prompt: refinementPrompt,
                systemInstruction: systemInstruction
            )

            // Parse the selected indices
            guard let parsed = JSONSanitizer.parse(response) as? [String: Any],
                  let indices = parsed["selected_indices"] as? [Int] else {
                Logger.warning("RecommendationGenerator: refinement parse failed, returning top 4 candidates")
                return Array(candidates.prefix(4))
            }

            // Map indices back to recommendations
            let refined = indices.compactMap { index -> Recommendation? in
                guard index >= 0 && index < candidates.count else { return nil }
                return candidates[index]
            }

            return refined.isEmpty ? Array(candidates.prefix(4)) : refined

        } catch {
            Logger.warning("RecommendationGenerator: refinement failed (\(error.localizedDescription)), returning top 4 candidates")
            return Array(candidates.prefix(4))
        }
    }

    /// Extract the user's primary focus from recent activity for refinement context.
    private func extractPrimaryFocus(
        from recentTasks: [String: [TaskRecord]],
        projectActivities: [ProjectActivity]
    ) -> String {
        var focusLines: [String] = []

        // Get today's date string
        let today = SharedFormatters.dayFormatter.string(from: Date())
        let yesterday = SharedFormatters.dayFormatter.string(
            from: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        )

        // Primary focus from today's tasks
        if let todayTasks = recentTasks[today], !todayTasks.isEmpty {
            let totalTime = todayTasks.reduce(0.0) { $0 + $1.duration }
            let topTask = todayTasks.max(by: { $0.duration < $1.duration })
            if let top = topTask {
                focusLines.append("Today's main work: \(top.title) (\(Int(top.duration / 60))m of \(Int(totalTime / 60))m total)")
            }
        }

        // Yesterday's context
        if let yesterdayTasks = recentTasks[yesterday], !yesterdayTasks.isEmpty {
            let topTask = yesterdayTasks.max(by: { $0.duration < $1.duration })
            if let top = topTask {
                focusLines.append("Yesterday's main work: \(top.title)")
            }
        }

        // Top project activity
        if let topProject = projectActivities.max(by: { $0.totalDuration < $1.totalDuration }) {
            focusLines.append("Current project: \(topProject.name) — \(topProject.summary)")
        }

        return focusLines.isEmpty ? "General work activity" : focusLines.joined(separator: "\n")
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

        // 1. User profile FIRST — this is the primary lens for personalization
        if let memory = memoryContext, !memory.isEmpty {
            lines.append("## User Profile")
            lines.append("This is what you know about this user. Use it to make every recommendation deeply relevant to their specific role, projects, goals, and interests.")
            lines.append(memory)
            lines.append("")
        }

        // 2. OCR-derived screen content — high-signal data about what was actually on screen
        if let digest = ocrDigest, !digest.isEmpty {
            lines.append("## Screen Content Analysis (extracted from screenshots)")
            lines.append("This is what was actually visible on screen — URLs visited, code being written, documents open, communications. Use this to understand what topics and resources the user is actively engaging with:")
            lines.append(digest)
            lines.append("")
        }

        // 3. Weekly trends — cross-day patterns
        if let trends = weeklyTrends, !trends.isEmpty {
            lines.append("## Weekly Patterns")
            lines.append(trends)
            lines.append("")
        }

        // 4. Recent tasks with RECENCY WEIGHTING
        // - Tier 1 (Today/Yesterday): Full detail — titles, descriptions, apps, links
        // - Tier 2 (2-3 days ago): Summarized — titles and durations only
        // - Tier 3 (4-7 days ago): Themes only — project names, no individual tasks
        lines.append("## Recent Activity Data")
        lines.append("(Note: Data is tiered by recency — TODAY is most important for recommendations)")
        lines.append("")

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Categorize dates into tiers
        var tier1Dates: [String] = []  // Today, Yesterday
        var tier2Dates: [String] = []  // 2-3 days ago
        var tier3Dates: [String] = []  // 4-7 days ago

        for dateStr in recentTasks.keys {
            guard let date = SharedFormatters.dayFormatter.date(from: dateStr) else { continue }
            let dayStart = calendar.startOfDay(for: date)
            let daysAgo = calendar.dateComponents([.day], from: dayStart, to: today).day ?? 0

            switch daysAgo {
            case 0...1: tier1Dates.append(dateStr)
            case 2...3: tier2Dates.append(dateStr)
            default: tier3Dates.append(dateStr)
            }
        }

        // Tier 1: Full detail (Today/Yesterday) — THIS IS WHAT MATTERS MOST
        if !tier1Dates.isEmpty {
            lines.append("### 🎯 CURRENT FOCUS (Today/Yesterday) — Prioritize recommendations for this work")
            for dateStr in tier1Dates.sorted().reversed() {
                guard let tasks = recentTasks[dateStr] else { continue }
                let isToday = dateStr == SharedFormatters.dayFormatter.string(from: Date())
                lines.append("#### \(dateStr)\(isToday ? " (TODAY)" : "")")
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
            }
            lines.append("")
        }

        // Tier 2: Summarized (2-3 days ago) — titles and durations only
        if !tier2Dates.isEmpty {
            lines.append("### Recent Context (2-3 days ago)")
            for dateStr in tier2Dates.sorted().reversed() {
                guard let tasks = recentTasks[dateStr] else { continue }
                lines.append("#### \(dateStr)")
                for task in tasks.prefix(10) {
                    let durMins = Int(task.duration / 60)
                    lines.append("- \"\(task.title)\" (\(durMins)m)")
                }
            }
            lines.append("")
        }

        // Tier 3: Themes only (4-7 days ago) — aggregate into project summaries
        if !tier3Dates.isEmpty {
            lines.append("### Background Context (4-7 days ago) — themes only")
            var projectTotals: [String: (minutes: Int, count: Int)] = [:]
            for dateStr in tier3Dates {
                guard let tasks = recentTasks[dateStr] else { continue }
                for task in tasks {
                    // Use first 3 words of title as a rough project key
                    let words = task.title.split(separator: " ").prefix(3).joined(separator: " ")
                    let key = words.isEmpty ? "Other" : words
                    let current = projectTotals[key] ?? (0, 0)
                    projectTotals[key] = (current.minutes + Int(task.duration / 60), current.count + 1)
                }
            }
            let sorted = projectTotals.sorted { $0.value.minutes > $1.value.minutes }
            for (theme, stats) in sorted.prefix(8) {
                lines.append("- \(theme): \(stats.minutes)m across \(stats.count) tasks")
            }
            lines.append("")
        }

        // 5. Project activities (higher-level grouping)
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

        // 6. Apps and time spent (weighted toward recent usage)
        if !appsUsed.isEmpty {
            lines.append("## Apps Used (sorted by time)")
            let sorted = appsUsed.sorted { $0.value > $1.value }
            for (app, seconds) in sorted.prefix(12) {
                let mins = Int(seconds / 60)
                if mins > 0 {
                    lines.append("- \(app): \(mins)m")
                }
            }
            lines.append("")
        }

        // 7. Detailed activity log — window titles, browser URLs, and document paths
        if let log = activityLog, !log.isEmpty {
            lines.append("## Today's Detailed Activity (window titles, URLs visited, files opened)")
            lines.append(log)
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
            "Help me optimize the SQLite queries",
            "Explain the WAL checkpoint strategy"
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
        - greeting_context: 1-2 warm, personal sentences (NO greeting/name — UI shows that) that reference the user's CURRENT projects by name
        - suggested_questions: 3-4 SHORT prompts (max 6-8 words each) tied to their CURRENT work. Mix questions ("Best approach for X?") and action requests ("Help me debug Y", "Explain Z"). At least one should be exploratory/interest-driven.

        Recommendation fields:
        - category: one of "article", "tool", "best_practice", "workflow", "learning", "exploration"
        - title: concise, specific title that would only make sense for THIS user's CURRENT work
        - description: 2-3 sentences explaining what this is and why it's valuable for their CURRENT situation
        - reason: 1 sentence citing specific tasks from TODAY or this week
        - action_url: ONLY use URLs you are 100% certain exist (homepages, top-level doc pages). Use null if uncertain — a missing link is better than a 404.
        - icon: an SF Symbol name (e.g. "doc.text", "wrench.and.screwdriver", "lightbulb", "arrow.triangle.branch", "book", "cpu", "network", "lock.shield", "swift", "terminal")

        IMPORTANT: Generate 6-8 recommendations. Prioritize TODAY'S work from the 🎯 CURRENT FOCUS section.
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
