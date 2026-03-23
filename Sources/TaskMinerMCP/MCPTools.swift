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
            description: "Get AI-generated task summaries for a date range. Returns task title, description, time range, apps used, and relevant links.",
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
            description: "Get raw activity records (app switches, window titles, idle periods). Shows what apps were used and when.",
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
                        "format": .string("date-time"),
                        "description": .string("Start time (ISO8601)")
                    ]),
                    "to": .object([
                        "type": .string("string"),
                        "format": .string("date-time"),
                        "description": .string("End time (ISO8601)")
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
            description: "Search activities by app name, window title, or content. Returns matching activity records.",
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
            description: "Get project activity summaries. Shows project names, durations, and associated tasks.",
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
            description: "Get the day view timeline showing tasks interleaved with away/idle periods.",
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
            description: "Get the day summary including focus time, meeting time, and AI-generated summary.",
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
            description: "Get the user's learned profile including role, projects, tech stack, and interests.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
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
        let date = try parseDate(params.date) ?? Date()
        var activities = await MainActor.run { dbReader.activities(for: date) }

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

        let stubsContent = await MainActor.run { dbReader.stubsContent(for: date) }

        var output: [String: Any] = [
            "date": SharedFormatters.dayFormatter.string(from: date)
        ]

        if let stubs = stubsContent {
            if let summary = stubs.daySummary {
                output["summary"] = DataSanitizer.sanitize(summary)
            }
            if let focusTime = stubs.focusTimeSeconds {
                output["focus_time_minutes"] = focusTime / 60
            }
            if let meetingTime = stubs.meetingTimeSeconds {
                output["meeting_time_minutes"] = meetingTime / 60
            }
            if let projectCount = stubs.projectCount {
                output["project_count"] = projectCount
            }
            output["generated_at"] = SharedFormatters.iso8601.string(from: stubs.generatedAt)
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

