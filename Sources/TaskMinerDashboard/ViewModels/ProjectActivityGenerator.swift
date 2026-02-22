import Foundation
import SwiftUI
import TaskMinerShared

/// Clusters TaskRecords into higher-level ProjectActivities using Gemini AI.
/// Lives in the Dashboard target (not Shared) because it's a view-model concern.
final class ProjectActivityGenerator: Sendable {
    private let geminiClient: GeminiClient


    init(geminiClient: GeminiClient) {
        self.geminiClient = geminiClient
    }

    // MARK: - Public API

    /// Cluster today's tasks into project-level activities using AI.
    func cluster(
        todayTasks: [TaskRecord],
        recentHistory: [String: [TaskRecord]],
        memoryContext: String?
    ) async throws -> [ProjectActivity] {
        guard !todayTasks.isEmpty else { return [] }

        let prompt = buildClusterPrompt(
            todayTasks: todayTasks,
            recentHistory: recentHistory,
            memoryContext: memoryContext
        )

        let systemInstruction = """
        You are a project clustering assistant for a desktop activity tracker called TaskMiner. \
        You group related tasks into higher-level project activities. \
        Use historical task data and user memory to recognise ongoing multi-day projects. \
        Give each project a clear, concise name (3-6 words). \
        Summaries should describe what was accomplished — not just list tasks. \
        Write in an impersonal style — never say "the user" or "you". \
        Respond with a JSON object. Do not include any text outside the JSON.
        """

        let response = try await geminiClient.generateContent(
            prompt: prompt,
            systemInstruction: systemInstruction
        )

        return try parseClusterResponse(response, todayTasks: todayTasks)
    }

    /// Fallback when AI is unavailable: one ProjectActivity per task.
    static func fallbackActivities(from tasks: [TaskRecord]) -> [ProjectActivity] {
        let paletteSize = Theme.barPalette.count
        return tasks
            .map { task in
                ProjectActivity(
                    id: UUID(),
                    name: task.title,
                    summary: task.description,
                    totalDuration: task.endTime.timeIntervalSince(task.startTime),
                    appNames: task.appNamesList,
                    taskTitles: [task.title],
                    startTime: task.startTime,
                    endTime: task.endTime,
                    colorIndex: ProjectActivity.stableColorIndex(for: task.title, paletteSize: paletteSize)
                )
            }
            .sorted { $0.totalDuration > $1.totalDuration }
    }

    // MARK: - Prompt Building

    private func buildClusterPrompt(
        todayTasks: [TaskRecord],
        recentHistory: [String: [TaskRecord]],
        memoryContext: String?
    ) -> String {
        var lines: [String] = []

        lines.append("Group the following tasks into higher-level project activities.")
        lines.append("Each task belongs to exactly one project. Related tasks should be merged.")
        lines.append("")

        // Today's tasks with indices
        lines.append("## Today's Tasks")
        lines.append("")
        for (index, task) in todayTasks.enumerated() {
            let start = SharedFormatters.timeFormatter.string(from: task.startTime)
            let end = SharedFormatters.timeFormatter.string(from: task.endTime)
            let dur = Int(task.endTime.timeIntervalSince(task.startTime) / 60)
            let apps = task.appNamesList.joined(separator: ", ")
            lines.append("[\(index)] \(start)-\(end) (\(dur)m) \"\(task.title)\" — \(apps)")
            if !task.description.isEmpty {
                lines.append("    \(task.description)")
            }
        }

        // Recent history for multi-day project recognition
        if !recentHistory.isEmpty {
            lines.append("")
            lines.append("## Recent History (for recognising ongoing projects)")
            lines.append("")
            let sortedDates = recentHistory.keys.sorted().reversed()
            for dateStr in sortedDates.prefix(7) {
                guard let tasks = recentHistory[dateStr] else { continue }
                let summaries = tasks.prefix(8).map { task in
                    let dur = Int(task.endTime.timeIntervalSince(task.startTime) / 60)
                    return "\"\(task.title)\" (\(dur)m)"
                }
                lines.append("\(dateStr): \(summaries.joined(separator: ", "))")
            }
        }

        // Memory context
        if let memory = memoryContext, !memory.isEmpty {
            lines.append("")
            lines.append("## Known Context")
            lines.append(memory)
        }

        // Output format
        lines.append("")
        lines.append("""
        ## Output Format
        Respond with a JSON object:
        {
          "projects": [
            {
              "name": "Authentication System Development",
              "summary": "Building and testing the login flow with input validation and error handling.",
              "task_indices": [0, 2, 5],
              "apps": ["Xcode", "Terminal"]
            }
          ]
        }

        Rules:
        - Every task index (0 to \(todayTasks.count - 1)) must appear in exactly one project
        - Order projects by total time spent (most time first)
        - Project names should be concise (3-6 words) and recognisable
        - If a task from today matches a pattern from recent history, use a consistent project name
        - Summaries describe what was accomplished, not just list task titles
        - A single task that doesn't relate to others can be its own project
        - apps should be the union of apps from constituent tasks
        """)

        return lines.joined(separator: "\n")
    }

    // MARK: - Response Parsing

    private func parseClusterResponse(_ response: String, todayTasks: [TaskRecord]) throws -> [ProjectActivity] {
        var jsonStr = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown fences
        if jsonStr.hasPrefix("```json") { jsonStr = String(jsonStr.dropFirst(7)) }
        else if jsonStr.hasPrefix("```") { jsonStr = String(jsonStr.dropFirst(3)) }
        if jsonStr.hasSuffix("```") { jsonStr = String(jsonStr.dropLast(3)) }
        jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find first JSON object
        if !jsonStr.hasPrefix("{"), let idx = jsonStr.firstIndex(of: "{") {
            jsonStr = String(jsonStr[idx...])
        }

        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = parsed["projects"] as? [[String: Any]]
        else {
            Logger.error("ProjectActivityGenerator: failed to parse response")
            return Self.fallbackActivities(from: todayTasks)
        }

        let paletteSize = Theme.barPalette.count
        var assignedIndices = Set<Int>()
        var result: [ProjectActivity] = []

        for project in projects {
            guard let name = project["name"] as? String,
                  let summary = project["summary"] as? String,
                  let indices = project["task_indices"] as? [Int]
            else { continue }

            // Filter to valid, unassigned indices
            let validIndices = indices.filter { $0 >= 0 && $0 < todayTasks.count && !assignedIndices.contains($0) }
            guard !validIndices.isEmpty else { continue }

            for idx in validIndices { assignedIndices.insert(idx) }

            let tasks = validIndices.map { todayTasks[$0] }
            let totalDuration = tasks.reduce(0.0) { $0 + $1.endTime.timeIntervalSince($1.startTime) }

            // Union of apps
            var appSet = Set<String>()
            var appList: [String] = []
            if let apps = project["apps"] as? [String] {
                for app in apps where appSet.insert(app).inserted {
                    appList.append(app)
                }
            } else {
                // Fall back to extracting from tasks
                for task in tasks {
                    for app in task.appNamesList where appSet.insert(app).inserted {
                        appList.append(app)
                    }
                }
            }

            let startTime = tasks.map(\.startTime).min() ?? tasks[0].startTime
            let endTime = tasks.map(\.endTime).max() ?? tasks[0].endTime

            result.append(ProjectActivity(
                id: UUID(),
                name: name,
                summary: summary,
                totalDuration: totalDuration,
                appNames: appList,
                taskTitles: tasks.map(\.title),
                startTime: startTime,
                endTime: endTime,
                colorIndex: ProjectActivity.stableColorIndex(for: name, paletteSize: paletteSize)
            ))
        }

        // Catch-all: any unassigned tasks go into "Other"
        let unassigned = todayTasks.indices.filter { !assignedIndices.contains($0) }
        if !unassigned.isEmpty {
            let tasks = unassigned.map { todayTasks[$0] }
            let totalDuration = tasks.reduce(0.0) { $0 + $1.endTime.timeIntervalSince($1.startTime) }
            var appSet = Set<String>()
            var appList: [String] = []
            for task in tasks {
                for app in task.appNamesList where appSet.insert(app).inserted {
                    appList.append(app)
                }
            }
            let startTime = tasks.map(\.startTime).min() ?? tasks[0].startTime
            let endTime = tasks.map(\.endTime).max() ?? tasks[0].endTime

            result.append(ProjectActivity(
                id: UUID(),
                name: "Other",
                summary: "Miscellaneous activities.",
                totalDuration: totalDuration,
                appNames: appList,
                taskTitles: tasks.map(\.title),
                startTime: startTime,
                endTime: endTime,
                colorIndex: ProjectActivity.stableColorIndex(for: "Other", paletteSize: paletteSize)
            ))
        }

        // Sort by duration descending
        result.sort { $0.totalDuration > $1.totalDuration }

        return result
    }
}
