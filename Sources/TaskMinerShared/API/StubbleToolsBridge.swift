import Foundation

/// Bridge between Stubble's MCP tools and Gemini function calling.
/// Allows the in-app chat to use the same tools as external MCP clients.
public final class StubbleToolsBridge: @unchecked Sendable {

    private let dbReader: DatabaseReader
    private let memoryStore: UserMemoryStore
    /// When the model omits `date`, use this day (e.g. the calendar day selected in the dashboard).
    private let defaultQueryDate: Date

    public init(dbReader: DatabaseReader, memoryStore: UserMemoryStore, defaultQueryDate: Date = Date()) {
        self.dbReader = dbReader
        self.memoryStore = memoryStore
        self.defaultQueryDate = defaultQueryDate
    }

    // MARK: - Gemini Function Declarations

    /// Get tool definitions formatted for Gemini function calling.
    public var geminiFunctionDeclarations: [[String: Any]] {
        [
            [
                "name": "get_time_by_app",
                "description": "Get total time spent in each application. Returns a breakdown of time by app name, sorted by duration. Use this when the user asks 'how much time did I spend on X?' or 'show time by app' or 'what apps did I use?'.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "date": [
                            "type": "string",
                            "description": "Date to query (YYYY-MM-DD). If omitted, use the day the user is viewing in Stubble."
                        ]
                    ]
                ]
            ],
            [
                "name": "query_tasks",
                "description": "Get AI-generated task summaries showing what the user worked on. Each task has a title, description, time range, and apps used. Use this when the user asks 'what did I work on?' or 'what have I been doing?' or needs context about their work.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "date": [
                            "type": "string",
                            "description": "Date to query (YYYY-MM-DD). If omitted, use the day the user is viewing in Stubble."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of tasks to return. Defaults to 40 for busy days."
                        ]
                    ]
                ]
            ],
            [
                "name": "get_projects",
                "description": "Get project-level work summaries showing what projects the user worked on and how long they spent on each. Use this for questions like 'what projects am I working on?' or 'summarize my projects'.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "date": [
                            "type": "string",
                            "description": "Date to query (YYYY-MM-DD). If omitted, use the day the user is viewing in Stubble."
                        ]
                    ]
                ]
            ],
            [
                "name": "get_timeline",
                "description": "Get a chronological view of the user's day showing tasks and breaks. Shows when they started working, took breaks, and ended their day. Use this for questions about daily schedule or 'describe my day'.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "date": [
                            "type": "string",
                            "description": "Date to query (YYYY-MM-DD). If omitted, use the day the user is viewing in Stubble."
                        ]
                    ]
                ]
            ],
            [
                "name": "get_day_summary",
                "description": "Get aggregate stats for a day (focus time, task count) plus optional AI day narrative, top apps, projects, and task titles. Pair with get_timeline and query_tasks for full 'describe my day' answers.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "date": [
                            "type": "string",
                            "description": "Date to query (YYYY-MM-DD). If omitted, use the day the user is viewing in Stubble."
                        ]
                    ]
                ]
            ],
            [
                "name": "get_user_profile",
                "description": "Get the user's learned profile including their role, projects, and technology stack. Use this to personalize assistance.",
                "parameters": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "search_activities",
                "description": "Search the user's activity history by keyword. Finds activities matching app names or window titles. Use this when looking for specific work like 'when did I work on X?'.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Search term (required)"
                        ],
                        "days": [
                            "type": "integer",
                            "description": "Number of days to search back. Defaults to 7."
                        ]
                    ],
                    "required": ["query"]
                ]
            ]
        ]
    }

    // MARK: - Tool Execution

    /// Execute a tool by name with the given arguments.
    public func execute(functionCall: GeminiClient.FunctionCall) async throws -> String {
        let args = functionCall.arguments
        let dateString = args["date"] as? String
        let date = parseDate(dateString) ?? defaultQueryDate

        switch functionCall.name {
        case "get_time_by_app":
            return await getTimeByApp(date: date)

        case "query_tasks":
            let limit = args["limit"] as? Int ?? 40
            return await queryTasks(date: date, limit: limit)

        case "get_projects":
            return await getProjects(date: date)

        case "get_timeline":
            return await getTimeline(date: date)

        case "get_day_summary":
            return await getDaySummary(date: date)

        case "get_user_profile":
            return getUserProfile()

        case "search_activities":
            guard let query = args["query"] as? String else {
                return "{\"error\": \"Missing required 'query' parameter\"}"
            }
            let days = args["days"] as? Int ?? 7
            return await searchActivities(query: query, days: days)

        default:
            return "{\"error\": \"Unknown function: \(functionCall.name)\"}"
        }
    }

    // MARK: - Tool Implementations

    private func getTimeByApp(date: Date) async -> String {
        let activities = await MainActor.run { dbReader.activities(for: date) }

        // Aggregate time by app
        var appDurations: [String: TimeInterval] = [:]
        for activity in activities where !activity.isIdle {
            let duration = activity.duration ?? 0
            appDurations[activity.appName, default: 0] += duration
        }

        // Sort by duration descending
        let sorted = appDurations.sorted { $0.value > $1.value }

        // Format output
        var apps: [[String: Any]] = []
        var totalMinutes = 0
        for (app, duration) in sorted {
            let minutes = Int(duration / 60)
            if minutes > 0 {
                totalMinutes += minutes
                apps.append([
                    "app": app,
                    "minutes": minutes,
                    "formatted": formatDuration(minutes)
                ])
            }
        }

        let result: [String: Any] = [
            "date": SharedFormatters.dayFormatter.string(from: date),
            "total_minutes": totalMinutes,
            "total_formatted": formatDuration(totalMinutes),
            "apps": apps
        ]

        return jsonString(result)
    }

    private func queryTasks(date: Date, limit: Int) async -> String {
        let tasks = await MainActor.run { dbReader.tasks(for: date) }
        let limited = Array(tasks.prefix(limit))

        var output: [[String: Any]] = []
        for task in limited {
            output.append([
                "title": DataSanitizer.sanitize(task.title),
                "description": DataSanitizer.sanitize(task.description),
                "start_time": SharedFormatters.timeFormatter.string(from: task.startTime),
                "end_time": SharedFormatters.timeFormatter.string(from: task.endTime),
                "duration_minutes": Int(task.duration / 60),
                "apps": task.appNamesList
            ])
        }

        let result: [String: Any] = [
            "date": SharedFormatters.dayFormatter.string(from: date),
            "tasks": output,
            "count": output.count
        ]

        return jsonString(result)
    }

    private func getProjects(date: Date) async -> String {
        let projects = await MainActor.run { dbReader.projectActivities(for: date) }

        var output: [[String: Any]] = []
        for project in projects {
            output.append([
                "name": project.name,
                "summary": DataSanitizer.sanitize(project.summary),
                "duration_minutes": Int(project.totalDuration / 60),
                "duration_formatted": formatDuration(Int(project.totalDuration / 60)),
                "apps": project.appNames,
                "task_count": project.taskTitles.count
            ])
        }

        let result: [String: Any] = [
            "date": SharedFormatters.dayFormatter.string(from: date),
            "projects": output,
            "count": output.count
        ]

        return jsonString(result)
    }

    private func getTimeline(date: Date) async -> String {
        let tasks = await MainActor.run { dbReader.tasks(for: date) }
        let activities = await MainActor.run { dbReader.activities(for: date) }

        // Build timeline items
        let timelineItems = TimelineItem.build(
            from: tasks,
            idleActivities: activities.filter { $0.isIdle },
            minIdleDuration: 120  // 2 minutes
        )

        var output: [[String: Any]] = []
        for item in timelineItems {
            switch item {
            case .task(let task, let isFirst, let isLast):
                output.append([
                    "type": "task",
                    "title": DataSanitizer.sanitize(task.title),
                    "start_time": SharedFormatters.timeFormatter.string(from: task.startTime),
                    "end_time": SharedFormatters.timeFormatter.string(from: task.endTime),
                    "duration_minutes": Int(task.duration / 60),
                    "is_first": isFirst,
                    "is_last": isLast
                ])
            case .gap(_, let start, let end, _):
                let duration = end.timeIntervalSince(start)
                output.append([
                    "type": "away",
                    "start_time": SharedFormatters.timeFormatter.string(from: start),
                    "end_time": SharedFormatters.timeFormatter.string(from: end),
                    "duration_minutes": Int(duration / 60)
                ])
            }
        }

        let result: [String: Any] = [
            "date": SharedFormatters.dayFormatter.string(from: date),
            "timeline": output,
            "count": output.count
        ]

        return jsonString(result)
    }

    private func getDaySummary(date: Date) async -> String {
        let stubsContent = await MainActor.run { dbReader.stubsContent(for: date) }
        let tasks = await MainActor.run { dbReader.tasks(for: date) }
        let activities = await MainActor.run { dbReader.activities(for: date) }
        let projects = await MainActor.run { dbReader.projectActivities(for: date) }

        // Calculate focus time (non-idle activity)
        let focusSeconds = activities
            .filter { !$0.isIdle }
            .reduce(0.0) { $0 + ($1.duration ?? 0) }

        let totalTaskMinutes = tasks.reduce(0) { $0 + Int($1.duration / 60) }

        // Top apps by non-idle duration (same semantics as get_time_by_app)
        var appDurations: [String: TimeInterval] = [:]
        for activity in activities where !activity.isIdle {
            let duration = activity.duration ?? 0
            appDurations[activity.appName, default: 0] += duration
        }
        let topApps = appDurations
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { name, dur -> [String: Any] in
                let mins = Int(dur / 60)
                return [
                    "app": name,
                    "minutes": mins,
                    "formatted": formatDuration(mins)
                ]
            }

        let taskPreview: [[String: Any]] = tasks.prefix(15).map { task in
            [
                "title": DataSanitizer.sanitize(task.title),
                "duration_minutes": Int(task.duration / 60),
                "start": SharedFormatters.timeFormatter.string(from: task.startTime),
                "end": SharedFormatters.timeFormatter.string(from: task.endTime)
            ]
        }

        let projectPreview: [[String: Any]] = projects.prefix(8).map { project in
            [
                "name": project.name,
                "duration_minutes": Int(project.totalDuration / 60),
                "summary": DataSanitizer.sanitize(project.summary)
            ]
        }

        var result: [String: Any] = [
            "date": SharedFormatters.dayFormatter.string(from: date),
            "focus_time_minutes": Int(focusSeconds / 60),
            "focus_time_formatted": formatDuration(Int(focusSeconds / 60)),
            "task_count": tasks.count,
            "total_task_minutes": totalTaskMinutes,
            "top_apps": topApps,
            "tasks_preview": taskPreview,
            "projects_preview": projectPreview
        ]

        if let summary = stubsContent?.daySummary, !summary.isEmpty {
            result["summary"] = summary
        }

        return jsonString(result)
    }

    private func getUserProfile() -> String {
        // contextString() returns synthesized profile if available,
        // otherwise falls back to categorized bullet list
        if let context = memoryStore.contextString() {
            return jsonString(["profile": context])
        }
        return jsonString(["profile": "No user profile available yet."])
    }

    private func searchActivities(query: String, days: Int) async -> String {
        var allActivities: [ActivityRecord] = []
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: endDate) ?? endDate

        var currentDate = startDate
        while currentDate <= endDate {
            let queryDate = currentDate
            let activities = await MainActor.run { dbReader.activities(for: queryDate) }
            allActivities.append(contentsOf: activities)
            currentDate = Calendar.current.date(byAdding: .day, value: 1, to: currentDate) ?? endDate
        }

        // Filter by query
        let lowercasedQuery = query.lowercased()
        let matches = allActivities.filter { activity in
            activity.appName.lowercased().contains(lowercasedQuery) ||
            (activity.windowTitle?.lowercased().contains(lowercasedQuery) ?? false)
        }

        // Limit results
        let limited = Array(matches.prefix(50))

        var output: [[String: Any]] = []
        for activity in limited {
            var record: [String: Any] = [
                "timestamp": SharedFormatters.iso8601.string(from: activity.timestamp),
                "app_name": activity.appName
            ]
            if let title = activity.windowTitle {
                record["window_title"] = DataSanitizer.sanitize(title)
            }
            if let duration = activity.duration {
                record["duration_minutes"] = Int(duration / 60)
            }
            output.append(record)
        }

        let result: [String: Any] = [
            "query": query,
            "days_searched": days,
            "matches": output,
            "count": output.count
        ]

        return jsonString(result)
    }

    // MARK: - Helpers

    private func parseDate(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        return SharedFormatters.dayFormatter.date(from: string)
    }

    private func formatDuration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 {
            return "\(hours)h \(mins)m"
        } else {
            return "\(mins)m"
        }
    }

    private func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
