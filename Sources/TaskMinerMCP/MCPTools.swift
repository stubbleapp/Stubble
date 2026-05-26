import Foundation
import TaskMinerShared

/// MCP tool implementations that expose Stubble data to AI agents.
/// All tools are read-only and apply data sanitization.
public final class MCPTools: @unchecked Sendable {

    private let dbReader: DatabaseReader
    private let memoryStore: UserMemoryStore

    public init(dbReader: DatabaseReader, memoryStore: UserMemoryStore) {
        self.dbReader = dbReader
        self.memoryStore = memoryStore
    }

    /// Tool definitions for MCP tools/list response
    public static let toolDefinitions: [MCPTool] = [
        MCPTool(
            name: "query_tasks",
            description: "Get what the user worked on. Returns AI-generated task summaries with titles, descriptions, time ranges, apps used, and relevant links. Use this when the user asks 'what did I work on?', 'what have I been doing?', or needs context about their recent work.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "date": .object([
                        "type": .string("string"),
                        "format": .string("date"),
                        "description": .string("Single date (YYYY-MM-DD). Defaults to today.")
                    ]),
                    "from": .object([
                        "type": .string("string"),
                        "format": .string("date"),
                        "description": .string("Start date for range query")
                    ]),
                    "to": .object([
                        "type": .string("string"),
                        "format": .string("date"),
                        "description": .string("End date for range query")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "default": .int(50),
                        "maximum": .int(200),
                        "description": .string("Maximum number of tasks to return")
                    ])
                ])
            ])
        ),
        MCPTool(
            name: "get_activity_log",
            description: "Get detailed activity records showing app usage, window titles, and idle periods. Use this when you need granular data about which apps were used, when, and for how long. Useful for time tracking questions like 'how much time did I spend in VS Code?' or understanding work patterns.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "date": .object([
                        "type": .string("string"),
                        "format": .string("date"),
                        "description": .string("Single date to query (YYYY-MM-DD). Defaults to today if no date range specified.")
                    ]),
                    "from": .object([
                        "type": .string("string"),
                        "format": .string("date"),
                        "description": .string("Start date for range query (YYYY-MM-DD)")
                    ]),
                    "to": .object([
                        "type": .string("string"),
                        "format": .string("date"),
                        "description": .string("End date for range query (YYYY-MM-DD). Defaults to today if 'from' is provided.")
                    ]),
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Filter by app name")
                    ]),
                    "include_idle": .object([
                        "type": .string("boolean"),
                        "default": .bool(true),
                        "description": .string("Include idle periods")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "default": .int(500),
                        "maximum": .int(2000),
                        "description": .string("Maximum number of records")
                    ])
                ])
            ])
        ),
        MCPTool(
            name: "search_activities",
            description: "Search the user's activity history by keyword. Finds activities matching app names, window titles, or content. Use this when looking for specific work like 'find when I worked on the login feature' or 'when did I last use Figma?'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Search term")
                    ]),
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Filter by app name")
                    ]),
                    "from": .object([
                        "type": .string("string"),
                        "format": .string("date-time"),
                        "description": .string("Start time (ISO8601)")
                    ]),
                    "to": .object([
                        "type": .string("string"),
                        "format": .string("date-time"),
                        "description": .string("End time (ISO8601)")
                    ]),
                    "include_urls": .object([
                        "type": .string("boolean"),
                        "default": .bool(false),
                        "description": .string("Include full URLs (privacy opt-in)")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        ),
        MCPTool(
            name: "get_projects",
            description: "Get project-level work summaries. Shows what projects the user worked on, how long they spent on each, and which tasks belong to each project. Use this for questions like 'what projects am I working on?' or 'how much time did I spend on Project X?'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "date": .object([
                        "type": .string("string"),
                        "format": .string("date"),
                        "description": .string("Date to query (YYYY-MM-DD). Defaults to today.")
                    ]),
                    "from": .object([
                        "type": .string("string"),
                        "format": .string("date"),
                        "description": .string("Start date for range")
                    ]),
                    "to": .object([
                        "type": .string("string"),
                        "format": .string("date"),
                        "description": .string("End date for range")
                    ])
                ])
            ])
        ),
        MCPTool(
            name: "get_timeline",
            description: "Get a chronological view of the user's day showing tasks and breaks. Shows when the user started working, took breaks, and ended their day. Use this for questions about daily schedule or work-life balance.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "date": .object([
                        "type": .string("string"),
                        "format": .string("date"),
                        "description": .string("Date to query (YYYY-MM-DD). Defaults to today.")
                    ])
                ])
            ])
        ),
        MCPTool(
            name: "get_day_summary",
            description: "Get a high-level summary of the user's day including total focus time, meeting time, and an AI-generated narrative of what was accomplished. Use this for quick overviews like 'how was my day?' or 'summarize what I did today'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "date": .object([
                        "type": .string("string"),
                        "format": .string("date"),
                        "description": .string("Date to query (YYYY-MM-DD). Defaults to today.")
                    ])
                ])
            ])
        ),
        MCPTool(
            name: "get_user_profile",
            description: "Get the user's profile learned from their work activity. Includes their role, current projects, technology stack, and interests. Use this to personalize assistance and understand the user's context. Call this first when you need to understand who the user is.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
        ),
        MCPTool(
            name: "get_ocr_digest",
            description: "Get structured data extracted from the user's screen content including URLs visited, file paths opened, code symbols seen, and terminal commands run. Use this when you need to know what specific content the user was looking at, like 'what documentation was I reading?' or 'what files did I have open?'.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "date": .object([
                        "type": .string("string"),
                        "format": .string("date"),
                        "description": .string("Date to query (YYYY-MM-DD). Defaults to today.")
                    ])
                ])
            ])
        )
    ]

    // MARK: - Tool Dispatch

    /// Execute a tool by name with the given parameters
    public func execute(tool: String, params: [String: JSONValue]?) async throws -> MCPToolResult {
        switch tool {
        case "query_tasks":
            return try await queryTasks(params: QueryTasksInput.parse(from: params))
        case "get_activity_log":
            return try await getActivityLog(params: GetActivityLogInput.parse(from: params))
        case "search_activities":
            return try await searchActivities(params: try SearchActivitiesInput.parse(from: params))
        case "get_projects":
            return try await getProjects(params: GetProjectsInput.parse(from: params))
        case "get_timeline":
            return try await getTimeline(params: GetTimelineInput.parse(from: params))
        case "get_day_summary":
            return try await getDaySummary(params: GetDaySummaryInput.parse(from: params))
        case "get_user_profile":
            return try await getUserProfile()
        case "get_ocr_digest":
            return try await getOCRDigest(params: GetOCRDigestInput.parse(from: params))
        default:
            throw MCPError.toolNotFound(tool)
        }
    }

    // MARK: - Tool Implementations

    private func queryTasks(params: QueryTasksInput) async throws -> MCPToolResult {
        let dates = try resolveDateRange(date: params.date, from: params.from, to: params.to)
        let limit = min(params.limit ?? 50, 200)

        var allTasks: [TaskRecord] = []
        for date in dates {
            let tasks = await MainActor.run { dbReader.tasks(for: date) }
            allTasks.append(contentsOf: tasks)
        }

        // Apply limit
        let limitedTasks = Array(allTasks.prefix(limit))

        // Format output
        var output: [[String: Any]] = []
        for task in limitedTasks {
            output.append([
                "title": DataSanitizer.sanitize(task.title),
                "description": DataSanitizer.sanitize(task.description),
                "start_time": SharedFormatters.iso8601.string(from: task.startTime),
                "end_time": SharedFormatters.iso8601.string(from: task.endTime),
                "duration_minutes": Int(task.duration / 60),
                "apps": task.appNamesList,
                "links": task.linksList.map { DataSanitizer.sanitize($0.value) },
                "websites": task.websitesList.map { sanitizeDomain($0) }
            ])
        }

        let json = try JSONSerialization.data(withJSONObject: ["tasks": output, "count": output.count], options: [.prettyPrinted, .sortedKeys])
        return MCPToolResult(text: String(data: json, encoding: .utf8) ?? "{}")
    }

    private func getActivityLog(params: GetActivityLogInput) async throws -> MCPToolResult {
        var activities: [ActivityRecord] = []

        // Handle date range vs single date
        if let fromStr = params.from {
            // Date range mode
            guard let fromDate = try parseDate(fromStr) else {
                throw MCPError.invalidDateFormat(fromStr)
            }
            let toDate = try parseDate(params.to) ?? Date()

            // Cap range at 30 days to prevent excessive queries
            let daysDiff = Calendar.current.dateComponents([.day], from: fromDate, to: toDate).day ?? 0
            if daysDiff > 30 {
                throw MCPError.internalError("Date range exceeds 30 days maximum")
            }
            if daysDiff < 0 {
                throw MCPError.internalError("'from' date must be before 'to' date")
            }

            // Query each day in the range
            var currentDate = fromDate
            while currentDate <= toDate {
                let queryDate = currentDate
                let dayActivities = await MainActor.run { dbReader.activities(for: queryDate) }
                activities.append(contentsOf: dayActivities)
                guard let next = Calendar.current.date(byAdding: .day, value: 1, to: currentDate) else { break }
                currentDate = next
            }
        } else {
            // Single date mode (existing behavior)
            let date = try parseDate(params.date) ?? Date()
            activities = await MainActor.run { dbReader.activities(for: date) }
        }

        // Filter by app if specified
        if let app = params.app {
            activities = activities.filter { $0.appName.localizedCaseInsensitiveContains(app) }
        }

        // Filter idle if requested
        if !params.includeIdle {
            activities = activities.filter { !$0.isIdle }
        }

        // Apply limit
        activities = Array(activities.prefix(params.limit))

        // Format output
        var output: [[String: Any]] = []
        for activity in activities {
            var record: [String: Any] = [
                "timestamp": SharedFormatters.iso8601.string(from: activity.timestamp),
                "app_name": activity.appName,
                "is_idle": activity.isIdle
            ]
            if let title = activity.windowTitle {
                record["window_title"] = DataSanitizer.sanitize(title)
            }
            if let duration = activity.duration {
                record["duration_seconds"] = Int(duration)
            }
            if let endTime = activity.endTime {
                record["end_time"] = SharedFormatters.iso8601.string(from: endTime)
            }
            // URLs redacted by default (domain only)
            if let url = activity.browserURL {
                record["browser_domain"] = sanitizeDomain(url)
            }
            // Document paths: basename only
            if let path = activity.documentPath {
                record["document_name"] = (path as NSString).lastPathComponent
            }
            output.append(record)
        }

        let json = try JSONSerialization.data(withJSONObject: ["activities": output, "count": output.count], options: [.prettyPrinted, .sortedKeys])
        return MCPToolResult(text: String(data: json, encoding: .utf8) ?? "{}")
    }

    private func searchActivities(params: SearchActivitiesInput) async throws -> MCPToolResult {
        // Get activities for the date range (default to last 7 days)
        let endDate = try parseDate(params.to) ?? Date()
        let startDate = try parseDate(params.from) ?? Calendar.current.date(byAdding: .day, value: -7, to: endDate)!

        var allActivities: [ActivityRecord] = []
        var currentDate = startDate
        while currentDate <= endDate {
            let queryDate = currentDate
            let activities = await MainActor.run { dbReader.activities(for: queryDate) }
            allActivities.append(contentsOf: activities)
            currentDate = Calendar.current.date(byAdding: .day, value: 1, to: currentDate)!
        }

        // Filter by query
        let query = params.query.lowercased()
        var matches = allActivities.filter { activity in
            if activity.appName.lowercased().contains(query) { return true }
            if let title = activity.windowTitle, title.lowercased().contains(query) { return true }
            if let url = activity.browserURL, url.lowercased().contains(query) { return true }
            return false
        }

        // Filter by app if specified
        if let app = params.app {
            matches = matches.filter { $0.appName.localizedCaseInsensitiveContains(app) }
        }

        // Limit results
        matches = Array(matches.prefix(100))

        // Format output
        var output: [[String: Any]] = []
        for activity in matches {
            var record: [String: Any] = [
                "timestamp": SharedFormatters.iso8601.string(from: activity.timestamp),
                "app_name": activity.appName
            ]
            if let title = activity.windowTitle {
                record["window_title"] = DataSanitizer.sanitize(title)
            }
            if params.includeUrls, let url = activity.browserURL {
                record["browser_url"] = DataSanitizer.sanitize(url)
            } else if let url = activity.browserURL {
                record["browser_domain"] = sanitizeDomain(url)
            }
            output.append(record)
        }

        let json = try JSONSerialization.data(withJSONObject: ["matches": output, "count": output.count, "query": params.query], options: [.prettyPrinted, .sortedKeys])
        return MCPToolResult(text: String(data: json, encoding: .utf8) ?? "{}")
    }

    private func getProjects(params: GetProjectsInput) async throws -> MCPToolResult {
        let dates = try resolveDateRange(date: params.date, from: params.from, to: params.to)

        var allProjects: [ProjectActivityRecord] = []
        for date in dates {
            let projects = await MainActor.run { dbReader.projectActivities(for: date) }
            allProjects.append(contentsOf: projects)
        }

        // Format output
        var output: [[String: Any]] = []
        for project in allProjects {
            output.append([
                "name": project.name,
                "summary": DataSanitizer.sanitize(project.summary),
                "duration_minutes": Int(project.totalDuration / 60),
                "start_time": SharedFormatters.iso8601.string(from: project.startTime),
                "end_time": SharedFormatters.iso8601.string(from: project.endTime),
                "apps": project.appNamesList,
                "tasks": project.taskTitlesList.map { DataSanitizer.sanitize($0) }
            ])
        }

        let json = try JSONSerialization.data(withJSONObject: ["projects": output, "count": output.count], options: [.prettyPrinted, .sortedKeys])
        return MCPToolResult(text: String(data: json, encoding: .utf8) ?? "{}")
    }

    private func getTimeline(params: GetTimelineInput) async throws -> MCPToolResult {
        let date = try parseDate(params.date) ?? Date()

        let tasks = await MainActor.run { dbReader.tasks(for: date) }
        let idleActivities = await MainActor.run { dbReader.idleActivities(for: date) }

        let timeline = TimelineItem.build(from: tasks, idleActivities: idleActivities, minIdleDuration: 120)

        var output: [[String: Any]] = []
        for item in timeline {
            switch item {
            case .task(let task, let isFirst, let isLast):
                output.append([
                    "type": "task",
                    "title": DataSanitizer.sanitize(task.title),
                    "start_time": SharedFormatters.iso8601.string(from: task.startTime),
                    "end_time": SharedFormatters.iso8601.string(from: task.endTime),
                    "duration_minutes": Int(task.duration / 60),
                    "is_first": isFirst,
                    "is_last": isLast
                ])
            case .gap(_, let startTime, let endTime, let duration):
                output.append([
                    "type": "away",
                    "start_time": SharedFormatters.iso8601.string(from: startTime),
                    "end_time": SharedFormatters.iso8601.string(from: endTime),
                    "duration_minutes": Int(duration / 60)
                ])
            }
        }

        let json = try JSONSerialization.data(withJSONObject: ["timeline": output, "count": output.count], options: [.prettyPrinted, .sortedKeys])
        return MCPToolResult(text: String(data: json, encoding: .utf8) ?? "{}")
    }

    private func getDaySummary(params: GetDaySummaryInput) async throws -> MCPToolResult {
        let date = try parseDate(params.date) ?? Date()

        let dayWrap = await MainActor.run { dbReader.timelineDayWrap(for: date) }

        var output: [String: Any] = [
            "date": SharedFormatters.dayFormatter.string(from: date)
        ]

        if let wrap = dayWrap {
            if let summary = wrap.summary {
                output["summary"] = DataSanitizer.sanitize(summary)
            }
            if let focusTime = wrap.focusTimeSeconds {
                output["focus_time_minutes"] = focusTime / 60
            }
            if let meetingTime = wrap.meetingTimeSeconds {
                output["meeting_time_minutes"] = meetingTime / 60
            }
            if let projectCount = wrap.projectCount {
                output["project_count"] = projectCount
            }
            output["generated_at"] = SharedFormatters.iso8601.string(from: wrap.updatedAt)
        } else {
            output["summary"] = nil
            output["message"] = "No summary available for this date"
        }

        let json = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        return MCPToolResult(text: String(data: json, encoding: .utf8) ?? "{}")
    }

    private func getUserProfile() async throws -> MCPToolResult {
        // Get memory context (synthesized profile or categorized facts)
        let context = memoryStore.contextString()

        var output: [String: Any] = [:]

        if let context = context {
            output["profile"] = DataSanitizer.sanitize(context)
        } else {
            output["profile"] = nil
            output["message"] = "No user profile available yet"
        }

        let json = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        return MCPToolResult(text: String(data: json, encoding: .utf8) ?? "{}")
    }

    private func getOCRDigest(params: GetOCRDigestInput) async throws -> MCPToolResult {
        let date = try parseDate(params.date) ?? Date()

        let digestRecord = await MainActor.run { dbReader.ocrDigestRecord(for: date) }

        var output: [String: Any] = [
            "date": SharedFormatters.dayFormatter.string(from: date)
        ]

        if let record = digestRecord {
            output["digest"] = DataSanitizer.sanitize(record.digest)
            output["generated_at"] = SharedFormatters.iso8601.string(from: record.generatedAt)
        } else {
            output["digest"] = nil
            output["message"] = "No OCR digest available for this date"
        }

        let json = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        return MCPToolResult(text: String(data: json, encoding: .utf8) ?? "{}")
    }

    // MARK: - Helpers

    private func parseDate(_ dateStr: String?) throws -> Date? {
        guard let dateStr = dateStr else { return nil }
        guard let date = SharedFormatters.dayFormatter.date(from: dateStr) else {
            throw MCPError.invalidDateFormat(dateStr)
        }
        return date
    }

    private func resolveDateRange(date: String?, from: String?, to: String?) throws -> [Date] {
        if let dateStr = date {
            guard let date = try parseDate(dateStr) else {
                return [Date()]
            }
            return [date]
        }

        if let fromStr = from, let toStr = to {
            guard let fromDate = try parseDate(fromStr),
                  let toDate = try parseDate(toStr) else {
                return [Date()]
            }

            var dates: [Date] = []
            var current = fromDate
            while current <= toDate {
                dates.append(current)
                guard let next = Calendar.current.date(byAdding: .day, value: 1, to: current) else { break }
                current = next
            }
            return dates
        }

        // Default to today
        return [Date()]
    }

    /// Extract domain from URL for privacy (strips path, query, fragment)
    private func sanitizeDomain(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else {
            // Try adding scheme
            if let url = URL(string: "https://\(urlString)"), let host = url.host {
                return host
            }
            return urlString
        }
        return host
    }
}

