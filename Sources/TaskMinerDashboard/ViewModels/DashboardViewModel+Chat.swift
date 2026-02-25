import Foundation
import TaskMinerShared

// MARK: - Chat

extension DashboardViewModel {

    private static let chatTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    func sendChatMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client = geminiClient else {
            chatError = "Gemini API key not configured"
            return
        }

        chatMessages.append(ChatMessage(role: .user, content: trimmed))
        isChatLoading = true
        chatError = nil
        Analytics.chatMessageSent()

        // Capture context for the async task
        let taskContext = buildChatTaskContext()
        let memoryContext = memoryStore.contextString()
        let history = buildConversationHistory()

        Task {
            do {
                let systemInstruction = """
                You are a helpful assistant embedded in a desktop activity tracker called Stubble. \
                You answer questions about the user's computer activity, tasks, and project activities for the day. \
                Be concise and conversational — keep responses short unless asked for detail. \
                Use markdown formatting (bold, italic, lists) to make responses clear and readable. \
                Use the provided task data, project activity context, and activity summaries to give accurate answers. \
                If the user asks about time, calculate it from the task start/end times provided. \
                Format durations as hours and minutes (e.g. "2h 15m"). \
                Never make up tasks, projects, or times that aren't in the context. \
                If you don't have enough information, say so.
                """

                let prompt = """
                Today's tasks and activity context:
                \(taskContext)
                \(memoryContext.map { "User context: \($0)" } ?? "")

                \(trimmed)
                """

                let response = try await client.generateText(
                    prompt: prompt,
                    systemInstruction: systemInstruction,
                    conversationHistory: history
                )

                self.chatMessages.append(ChatMessage(role: .assistant, content: response))
                // Keep chat history bounded to prevent unbounded memory growth
                if self.chatMessages.count > 50 {
                    self.chatMessages.removeFirst(self.chatMessages.count - 50)
                }
                self.isChatLoading = false
            } catch {
                self.chatError = error.localizedDescription
                self.isChatLoading = false
            }
        }
    }

    func clearChat() {
        chatMessages = []
        chatError = nil
        isChatLoading = false
    }

    /// Build a text block summarizing the current day's tasks and project activities for chat context.
    func buildChatTaskContext() -> String {
        guard !tasks.isEmpty else { return "No tasks recorded for this day." }

        var lines: [String] = []
        lines.append("Date: \(SharedFormatters.longDateFormatter.string(from: selectedDate))")

        if let summary = daySummaryText {
            lines.append("Day summary: \(summary)")
        }

        let totalActive = Int(activeSeconds)
        let hours = totalActive / 3600
        let mins = (totalActive % 3600) / 60
        lines.append("Total active time: \(hours)h \(mins)m")

        // Project activities (higher-level grouping)
        if !projectActivities.isEmpty {
            lines.append("")
            lines.append("Project Activities (\(projectActivities.count) projects):")
            for activity in projectActivities {
                let durMins = Int(activity.totalDuration) / 60
                let start = SharedFormatters.timeFormatter.string(from: activity.startTime)
                let end = SharedFormatters.timeFormatter.string(from: activity.endTime)
                lines.append("- \(activity.name) [\(start)–\(end)] (\(durMins)m)")
                if !activity.summary.isEmpty {
                    lines.append("  Summary: \(activity.summary)")
                }
                if !activity.appNames.isEmpty {
                    lines.append("  Apps: \(activity.appNames.joined(separator: ", "))")
                }
                if !activity.taskTitles.isEmpty {
                    lines.append("  Tasks: \(activity.taskTitles.joined(separator: "; "))")
                }
            }
        }

        // Individual tasks (granular detail)
        lines.append("")
        lines.append("Tasks:")

        for task in tasks {
            let start = SharedFormatters.timeFormatter.string(from: task.startTime)
            let end = SharedFormatters.timeFormatter.string(from: task.endTime)
            let duration = Int(task.duration)
            let durMins = duration / 60
            let apps = task.appNamesList.joined(separator: ", ")
            lines.append("- [\(start)–\(end)] (\(durMins)m) \(task.title)")
            if !task.description.isEmpty {
                lines.append("  \(task.description)")
            }
            if !apps.isEmpty {
                lines.append("  Apps: \(apps)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Build Gemini-compatible conversation history from previous messages (excluding the latest user message).
    /// Limits to the most recent 20 messages to avoid exceeding Gemini's context window.
    func buildConversationHistory() -> [[String: Any]]? {
        // All messages except the last one (which is the new user message sent as the prompt)
        let previous = chatMessages.dropLast()
        guard !previous.isEmpty else { return nil }

        // Keep only the last 20 messages to stay within token limits
        let recent = previous.suffix(20)

        return recent.map { msg in
            [
                "role": msg.role == .user ? "user" : "model",
                "parts": [["text": msg.content]]
            ] as [String: Any]
        }
    }
}
