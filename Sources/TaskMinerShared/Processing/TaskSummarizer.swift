import Foundation

/// Input data for AI summarization — combines activity + OCR info
public struct SummarizationInput: Sendable {
    public let appName: String
    public let bundleId: String?
    public let windowTitle: String?
    public let timestamp: Date
    public let duration: TimeInterval?
    public let isIdle: Bool
    public let ocrText: String?

    public init(
        appName: String,
        bundleId: String?,
        windowTitle: String?,
        timestamp: Date,
        duration: TimeInterval?,
        isIdle: Bool,
        ocrText: String?
    ) {
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.timestamp = timestamp
        self.duration = duration
        self.isIdle = isIdle
        self.ocrText = ocrText
    }
}

/// Result of AI summarization: tasks plus an optional natural-language day overview.
public struct SummarizationResult: Sendable {
    public let tasks: [TaskRecord]
    public let daySummary: String?
    public let newMemoryEntries: [String]
}

/// Builds prompts from activity data and parses Gemini responses into TaskRecords.
public final class TaskSummarizer: Sendable {
    private let geminiClient: GeminiClient

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public init(geminiClient: GeminiClient) {
        self.geminiClient = geminiClient
    }

    /// Summarize activity data into high-level tasks plus a day overview using Gemini AI.
    /// Optionally accepts existing memory context and returns new memory entries to merge.
    public func summarize(
        activities: [SummarizationInput],
        date: Date,
        customPrompt: String? = nil,
        memoryContext: String? = nil
    ) async throws -> SummarizationResult {
        guard !activities.isEmpty else { return SummarizationResult(tasks: [], daySummary: nil, newMemoryEntries: []) }

        let prompt = buildPrompt(from: activities)

        let userRules: String
        if let custom = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            userRules = "\nAdditional user instructions (always obey these): \(custom)"
        } else {
            userRules = ""
        }

        let memorySection: String
        if let mem = memoryContext, !mem.isEmpty {
            memorySection = """
            \nYou have the following knowledge about this person from previous sessions. \
            Use it to produce more accurate, consistent task titles and descriptions. \
            Reference known project names, tools, and patterns where relevant:\n\(mem)
            """
        } else {
            memorySection = ""
        }

        let systemInstruction = """
        You are a task mining assistant. You analyze computer activity logs and OCR text from screenshots \
        to identify high-level tasks. Group related activities into coherent tasks. \
        Each task should represent a meaningful work unit. \
        Titles must start with a present participle verb (e.g., "Developing auth flow in Xcode", \
        "Browsing documentation on MDN", "Watching conference talk on YouTube"). \
        Descriptions should be written in an impersonal tone — never say "the user" or "you". \
        Write as if labelling the activity directly (e.g., "Iterating on login validation logic across \
        multiple Swift files" not "The user was working on login validation"). \
        Silently omit any activity related to adult, explicit, or NSFW content — do not create tasks for it \
        and do not mention it in the day summary. \
        Respond with a JSON object containing "tasks" and "day_summary". Do not include any text outside the JSON.\(memorySection)\(userRules)
        """

        let response = try await geminiClient.generateContent(
            prompt: prompt,
            systemInstruction: systemInstruction
        )

        #if DEBUG
        if let debugDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let debugFile = debugDir.appendingPathComponent("TaskMiner").appendingPathComponent("last_gemini_response.txt")
            try? response.write(to: debugFile, atomically: true, encoding: .utf8)
            Logger.debug("Gemini raw response written to \(debugFile.path)")
        }
        #endif

        var result = try parseResponse(response, date: date)

        // Second call: extract memory updates from what was just observed
        let memoryEntries = await extractMemory(from: activities, existingMemory: memoryContext)
        result = SummarizationResult(tasks: result.tasks, daySummary: result.daySummary, newMemoryEntries: memoryEntries)

        return result
    }

    // MARK: - Memory Extraction

    /// Ask the AI to identify new facts about the user from today's activity.
    private func extractMemory(from activities: [SummarizationInput], existingMemory: String?) async -> [String] {
        let appNames = Set(activities.map { $0.appName }).sorted()
        let windowTitles = activities.compactMap { $0.windowTitle }.prefix(20)

        var prompt = """
        Based on the following desktop activity, identify factual observations about this person \
        that would be useful to remember for future sessions. Focus on:
        - Project names and what they involve
        - Technologies, languages, and tools used regularly
        - Work patterns (e.g., "primarily works in Swift using Xcode")
        - Key repositories or codebases

        Apps used: \(appNames.joined(separator: ", "))
        Sample window titles: \(windowTitles.joined(separator: " | "))
        """

        if let existing = existingMemory, !existing.isEmpty {
            prompt += """

            Already known (do NOT repeat these):
            \(existing)

            Only return NEW facts not already covered above.
            """
        }

        prompt += """

        Respond with a JSON array of short factual strings. Each should be a single concise sentence.
        If there is nothing new to learn, return an empty array [].
        Example: ["Works on a macOS app called TaskMiner using SwiftUI", "Uses Gemini API for AI features"]
        """

        let systemInstruction = """
        You extract factual observations about a person from their computer activity. \
        Return ONLY a JSON array of strings. No markdown, no explanation. \
        Each entry must be a short, factual, third-person statement. \
        Never include sensitive data like passwords, tokens, or personal messages.
        """

        do {
            let response = try await geminiClient.generateContent(
                prompt: prompt,
                systemInstruction: systemInstruction
            )

            var jsonStr = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if jsonStr.hasPrefix("```json") { jsonStr = String(jsonStr.dropFirst(7)) }
            else if jsonStr.hasPrefix("```") { jsonStr = String(jsonStr.dropFirst(3)) }
            if jsonStr.hasSuffix("```") { jsonStr = String(jsonStr.dropLast(3)) }
            jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)

            // Find array in response
            if !jsonStr.hasPrefix("["), let idx = jsonStr.firstIndex(of: "[") {
                jsonStr = String(jsonStr[idx...])
            }

            guard let data = jsonStr.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
            else {
                Logger.debug("Memory extraction: could not parse response")
                return []
            }

            Logger.debug("Memory extraction: \(arr.count) new entries")
            return arr
        } catch {
            Logger.debug("Memory extraction failed (non-fatal): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Prompt Building

    /// Pre-aggregate consecutive activity entries that share the same app into blocks.
    /// This prevents the AI from creating a new task per screenshot interval.
    private struct ActivityBlock {
        let appName: String
        let startTime: Date
        var endTime: Date
        var windowTitles: [String]
        var totalDuration: TimeInterval
        var ocrSamples: [String]
    }

    private func aggregateActivities(_ activities: [SummarizationInput]) -> [ActivityBlock] {
        var blocks: [ActivityBlock] = []

        for activity in activities where !activity.isIdle {
            let title = activity.windowTitle ?? "(no title)"
            let dur = activity.duration ?? 0

            if var last = blocks.last, last.appName == activity.appName {
                // Extend the current block
                last.endTime = activity.timestamp.addingTimeInterval(dur)
                last.totalDuration += dur
                if !last.windowTitles.contains(title) {
                    last.windowTitles.append(title)
                }
                if let ocr = activity.ocrText, !ocr.isEmpty, last.ocrSamples.count < 3 {
                    let trimmed = String(ocr.prefix(400))
                    if !last.ocrSamples.contains(where: { $0.prefix(80) == trimmed.prefix(80) }) {
                        last.ocrSamples.append(trimmed)
                    }
                }
                blocks[blocks.count - 1] = last
            } else {
                // Start a new block
                var ocrSamples: [String] = []
                if let ocr = activity.ocrText, !ocr.isEmpty {
                    ocrSamples.append(String(ocr.prefix(400)))
                }
                blocks.append(ActivityBlock(
                    appName: activity.appName,
                    startTime: activity.timestamp,
                    endTime: activity.timestamp.addingTimeInterval(dur),
                    windowTitles: [title],
                    totalDuration: dur,
                    ocrSamples: ocrSamples
                ))
            }
        }

        return blocks
    }

    private func buildPrompt(from activities: [SummarizationInput]) -> String {
        let blocks = aggregateActivities(activities)

        var lines: [String] = []
        lines.append("Analyze the following desktop activity log and identify the high-level tasks.")
        lines.append("Each entry below is a block of continuous activity in one app — some blocks may belong to the same task.")
        lines.append("")
        lines.append("## Activity Log")
        lines.append("")

        var ocrSections: [(time: String, text: String)] = []

        for block in blocks {
            let start = Self.timeFormatter.string(from: block.startTime)
            let end = Self.timeFormatter.string(from: block.endTime)
            let dur = "\(Int(block.totalDuration))s"
            let titles = block.windowTitles.prefix(5).joined(separator: " | ")
            lines.append("[\(start)–\(end)] \(block.appName) (\(dur)) — \(titles)")

            // Collect OCR samples (limit total to 10)
            for ocr in block.ocrSamples where ocrSections.count < 10 {
                ocrSections.append((time: start, text: ocr))
            }
        }

        if !ocrSections.isEmpty {
            lines.append("")
            lines.append("## Screen Content (OCR)")
            lines.append("")
            for sample in ocrSections {
                lines.append("[\(sample.time)] \(sample.text)")
                lines.append("---")
            }
        }

        lines.append("")
        lines.append("""
        ## Output Format
        Respond with a JSON object containing "tasks" and "day_summary":
        {
          "day_summary": "A concise 2–3 sentence overview of the day, emphasising where most time was spent and the main focus areas.",
          "tasks": [
            {
              "title": "Developing auth flow in Xcode",
              "description": "Iterating on login validation logic across multiple Swift files.",
              "start_time": "HH:mm:ss",
              "end_time": "HH:mm:ss",
              "app_names": ["Xcode"],
              "confidence": 0.85
            }
          ]
        }

        Rules:
        - Aggressively merge related activity into coarser tasks — aim for roughly 3–8 tasks per full day
        - If the same project or topic appears in multiple blocks (even separated by short breaks or other apps), merge them into ONE task that spans the full time range
        - Every task title MUST be unique — never produce two tasks with the same or near-identical title
        - Titles MUST start with a present participle verb (e.g., Developing, Browsing, Watching, Reviewing, Debugging)
        - Descriptions must be impersonal — never write "the user", "you", or "they". Describe the activity directly.
        - day_summary should be written in a direct, impersonal style — describe what was worked on and where the bulk of time went. Never say "the user" or "you".
        - confidence should be 0.0-1.0 based on how certain you are
        - Times should be based on the activity timestamps — use the earliest start and latest end for merged tasks
        - Ignore idle periods
        - Silently skip any activity involving adult, explicit, or NSFW content — never include it in tasks or the day summary
        - If there's not enough information, return {"tasks": [], "day_summary": null}
        """)

        return lines.joined(separator: "\n")
    }

    // MARK: - Response Parsing

    private func parseResponse(_ response: String, date: Date) throws -> SummarizationResult {
        var jsonStr = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonStr.hasPrefix("```json") {
            jsonStr = String(jsonStr.dropFirst(7))
        } else if jsonStr.hasPrefix("```") {
            jsonStr = String(jsonStr.dropFirst(3))
        }
        if jsonStr.hasSuffix("```") {
            jsonStr = String(jsonStr.dropLast(3))
        }
        jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the response doesn't start with { or [, try to find the first JSON structure
        if !jsonStr.hasPrefix("{") && !jsonStr.hasPrefix("[") {
            if let braceIdx = jsonStr.firstIndex(of: "{") {
                jsonStr = String(jsonStr[braceIdx...])
            } else if let bracketIdx = jsonStr.firstIndex(of: "[") {
                jsonStr = String(jsonStr[bracketIdx...])
            }
        }

        Logger.debug("Gemini response (\(jsonStr.count) chars): \(String(jsonStr.prefix(500)))")

        guard let data = jsonStr.data(using: .utf8) else {
            throw GeminiError.parseError("Response is not valid UTF-8")
        }

        let array: [[String: Any]]
        var daySummary: String?
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            if let arr = parsed as? [[String: Any]] {
                array = arr
            } else if let obj = parsed as? [String: Any] {
                daySummary = obj["day_summary"] as? String
                if let arr = obj["tasks"] as? [[String: Any]] {
                    array = arr
                } else if let arr = obj["results"] as? [[String: Any]] {
                    array = arr
                } else if let arr = obj.values.compactMap({ $0 as? [[String: Any]] }).first {
                    array = arr
                } else {
                    throw GeminiError.parseError("JSON object has no task array. Keys: \(Array(obj.keys)). Preview: \(String(jsonStr.prefix(300)))")
                }
            } else {
                throw GeminiError.parseError("Unexpected JSON type. Preview: \(String(jsonStr.prefix(300)))")
            }
        } catch let error as GeminiError {
            throw error
        } catch {
            throw GeminiError.parseError("Invalid JSON: \(error.localizedDescription). Preview: \(String(jsonStr.prefix(300)))")
        }

        let dateStr = Self.dateFormatter.string(from: date)
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)

        let tasks = array.compactMap { dict -> TaskRecord? in
            guard let title = dict["title"] as? String,
                  let startTimeStr = dict["start_time"] as? String,
                  let endTimeStr = dict["end_time"] as? String
            else { return nil }

            guard let startTime = parseTime(startTimeStr, relativeTo: startOfDay),
                  let endTime = parseTime(endTimeStr, relativeTo: startOfDay)
            else { return nil }

            let description = dict["description"] as? String ?? ""
            let confidence = dict["confidence"] as? Double ?? 0.5
            let appNames = dict["app_names"] as? [String] ?? []
            let appNamesJSON = (try? JSONSerialization.data(withJSONObject: appNames))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            return TaskRecord(
                date: dateStr,
                startTime: startTime,
                endTime: endTime,
                title: title,
                description: description,
                appNames: appNamesJSON,
                confidence: confidence
            )
        }

        let merged = Self.mergeDuplicateTasks(tasks)
        return SummarizationResult(tasks: merged, daySummary: daySummary, newMemoryEntries: [])
    }

    /// Post-processing: merge tasks that share the same title into a single task
    /// spanning the full time range, combining descriptions and apps.
    private static func mergeDuplicateTasks(_ tasks: [TaskRecord]) -> [TaskRecord] {
        guard tasks.count > 1 else { return tasks }

        var groups: [String: [TaskRecord]] = [:]
        var order: [String] = []

        for task in tasks {
            let key = task.title.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(task)
        }

        return order.compactMap { key -> TaskRecord? in
            guard let group = groups[key], let first = group.first else { return nil }
            if group.count == 1 { return first }

            let startTime = group.map(\.startTime).min() ?? first.startTime
            let endTime = group.map(\.endTime).max() ?? first.endTime
            let confidence = group.map(\.confidence).max() ?? first.confidence

            // Merge descriptions — take longest or combine unique ones
            let descs = group.map(\.description).filter { !$0.isEmpty }
            let mergedDesc = descs.max(by: { $0.count < $1.count }) ?? first.description

            // Merge app names
            var appSet = Set<String>()
            var appList: [String] = []
            for t in group {
                for app in t.appNamesList where appSet.insert(app).inserted {
                    appList.append(app)
                }
            }
            let appNamesJSON = (try? JSONSerialization.data(withJSONObject: appList))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            return TaskRecord(
                date: first.date,
                startTime: startTime,
                endTime: endTime,
                title: first.title,
                description: mergedDesc,
                appNames: appNamesJSON,
                confidence: confidence
            )
        }
    }

    private func parseTime(_ timeStr: String, relativeTo startOfDay: Date) -> Date? {
        let parts = timeStr.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }

        var components = DateComponents()
        components.hour = parts[0]
        components.minute = parts[1]
        components.second = parts.count > 2 ? parts[2] : 0

        return Calendar.current.date(byAdding: components, to: startOfDay)
    }
}
