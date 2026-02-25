import Foundation
import TaskMinerShared

// MARK: - Chat

extension DashboardViewModel {

    private static let chatTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// The date string for the currently selected date (yyyy-MM-dd).
    private var selectedDateString: String {
        SharedFormatters.dayFormatter.string(from: selectedDate)
    }

    /// Load persisted chat messages for the selected date.
    func loadChatHistory() {
        guard let db = dbReader else { return }
        let records = db.chatMessages(for: selectedDate)
        chatMessages = records.map { ChatMessage(from: $0) }
    }

    /// Persist a single message to the database and store its row ID.
    private func persistMessage(_ message: ChatMessage) {
        guard let writer = taskWriter else { return }
        let record = message.toRecord(date: selectedDateString)
        do {
            let rowId = try writer.insertChatMessage(record)
            message.dbId = rowId
        } catch {
            Logger.error("Failed to persist chat message: \(error.localizedDescription)")
        }
    }

    func sendChatMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client = geminiClient else {
            chatError = "Gemini API key not configured"
            return
        }

        let userMessage = ChatMessage(role: .user, content: trimmed)
        chatMessages.append(userMessage)
        persistMessage(userMessage)

        isChatLoading = true
        chatError = nil
        Analytics.chatMessageSent()

        // Capture context for the async task
        let taskContext = buildChatTaskContext()
        let memoryContext = memoryStore.contextString()
        let history = buildConversationHistory()
        let screenContext = currentScreen

        // Create empty assistant message for streaming
        let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        chatMessages.append(assistantMessage)

        Task {
            do {
                let systemInstruction = """
                You are a friendly personal assistant embedded in a desktop activity tracker called Stubble. \
                You know about the user's day — their tasks, apps, and how they spent their time. \
                Be warm, casual, and concise — like a helpful colleague who's been watching the day unfold. \
                Keep responses short and punchy unless the user asks for detail. \
                Use markdown formatting (bold, italic, lists) when it helps readability. \
                Use the provided task data, project activity context, and activity summaries to give accurate answers. \
                If the user asks about time, calculate it from the task start/end times provided. \
                Format durations as hours and minutes (e.g. "2h 15m"). \
                Never make up tasks, projects, or times that aren't in the context. \
                If you don't have enough information, just say so honestly.
                """

                let prompt = """
                Today's tasks and activity context:
                \(taskContext)
                \(memoryContext.map { "User context: \($0)" } ?? "")
                The user is currently viewing the "\(screenContext)" screen.

                \(trimmed)
                """

                for try await chunk in client.streamGenerateText(
                    prompt: prompt,
                    systemInstruction: systemInstruction,
                    conversationHistory: history
                ) {
                    assistantMessage.content += chunk
                }

                assistantMessage.isStreaming = false
                self.isChatLoading = false

                // Persist the complete assistant message
                self.persistMessage(assistantMessage)

                // Keep chat history bounded to prevent unbounded memory growth
                if self.chatMessages.count > 50 {
                    self.chatMessages.removeFirst(self.chatMessages.count - 50)
                }
            } catch {
                // Remove the empty assistant message on error
                if assistantMessage.content.isEmpty {
                    self.chatMessages.removeAll { $0.id == assistantMessage.id }
                } else {
                    // Keep partial content but mark streaming as done
                    assistantMessage.isStreaming = false
                    self.persistMessage(assistantMessage)
                }
                self.chatError = error.localizedDescription
                self.isChatLoading = false
            }
        }
    }

    func clearChat() {
        chatMessages = []
        chatError = nil
        isChatLoading = false

        // Also clear from database
        if let writer = taskWriter {
            try? writer.deleteChatMessages(for: selectedDateString)
        }
    }

    /// Build a text block summarizing the current day's tasks, activities, and window titles for chat context.
    func buildChatTaskContext() -> String {
        guard !activities.isEmpty || !tasks.isEmpty else { return "No activity recorded for this day." }

        var lines: [String] = []
        lines.append("Date: \(SharedFormatters.longDateFormatter.string(from: selectedDate))")

        if let summary = daySummaryText {
            lines.append("Day summary: \(summary)")
        }

        let totalActive = Int(activeSeconds)
        let hours = totalActive / 3600
        let mins = (totalActive % 3600) / 60
        lines.append("Total active time: \(hours)h \(mins)m")

        // Detailed activity log — this is the most granular data, with exact window titles and durations
        if !groupedActivities.isEmpty {
            lines.append("")
            lines.append("Activity log (chronological — each entry is a continuous session in one app):")
            for group in groupedActivities {
                let start = group.startTime.map { SharedFormatters.timeFormatter.string(from: $0) } ?? "?"
                let end = group.endTime.map { SharedFormatters.timeFormatter.string(from: $0) } ?? "?"
                let durMins = Int(group.totalDuration) / 60
                lines.append("- [\(start)–\(end)] \(group.appName) (\(durMins)m)")
                // Include window titles — these have the real detail (URLs, document names, etc.)
                let titles = group.windowTitles.prefix(5)
                for title in titles {
                    lines.append("  · \(title)")
                }
            }
        }

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
            }
        }

        // AI-generated tasks (higher-level interpretation)
        if !tasks.isEmpty {
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
        }

        return lines.joined(separator: "\n")
    }

    /// Build Gemini-compatible conversation history from previous messages (excluding the latest user message).
    /// Limits to the most recent 20 messages to avoid exceeding Gemini's context window.
    func buildConversationHistory() -> [[String: Any]]? {
        // All messages except the last two (the new user message and the empty streaming assistant message)
        let previous = chatMessages.dropLast(2)
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
