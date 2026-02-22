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
    public func summarize(activities: [SummarizationInput], date: Date, customPrompt: String? = nil) async throws -> SummarizationResult {
        guard !activities.isEmpty else { return SummarizationResult(tasks: [], daySummary: nil) }

        let prompt = buildPrompt(from: activities)

        let userRules: String
        if let custom = customPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            userRules = "\nAdditional user instructions (always obey these): \(custom)"
        } else {
            userRules = ""
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
        Respond with a JSON object containing "tasks" and "day_summary". Do not include any text outside the JSON.\(userRules)
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

        return try parseResponse(response, date: date)
    }

    // MARK: - Prompt Building

    private func buildPrompt(from activities: [SummarizationInput]) -> String {
        var lines: [String] = []
        lines.append("Analyze the following desktop activity log and identify the high-level tasks:")
        lines.append("")
        lines.append("## Activity Log")
        lines.append("")

        // Deduplicate and summarize activities
        var seenOCR = Set<String>()
        var ocrSamples: [(time: String, text: String)] = []

        for activity in activities where !activity.isIdle {
            let time = Self.timeFormatter.string(from: activity.timestamp)
            let dur = activity.duration.map { "\(Int($0))s" } ?? "?"
            let title = activity.windowTitle ?? "(no title)"
            lines.append("[\(time)] \(activity.appName) — \(title) (\(dur))")

            // Collect unique OCR samples (max 10, max 500 chars each)
            if let ocr = activity.ocrText, !ocr.isEmpty, ocrSamples.count < 10 {
                let trimmed = String(ocr.prefix(500))
                let hash = String(trimmed.prefix(100))
                if !seenOCR.contains(hash) {
                    seenOCR.insert(hash)
                    ocrSamples.append((time: time, text: trimmed))
                }
            }
        }

        if !ocrSamples.isEmpty {
            lines.append("")
            lines.append("## Screen Content (OCR)")
            lines.append("")
            for sample in ocrSamples {
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
        - Group related activities into a single task
        - Titles MUST start with a present participle verb (e.g., Developing, Browsing, Watching, Reviewing, Debugging)
        - Descriptions must be impersonal — never write "the user", "you", or "they". Describe the activity directly.
        - day_summary should be written in a direct, impersonal style — describe what was worked on and where the bulk of time went. Never say "the user" or "you".
        - confidence should be 0.0-1.0 based on how certain you are
        - Times should be based on the activity timestamps
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

        return SummarizationResult(tasks: tasks, daySummary: daySummary)
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
