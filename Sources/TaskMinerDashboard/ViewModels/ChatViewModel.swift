import Foundation
import TaskMinerShared

/// Manages chat state separate from the main DashboardViewModel.
/// This is a lightweight state container — actual operations are delegated to
/// DashboardViewModel+Chat.swift extension methods.
@Observable
@MainActor
final class ChatViewModel {

    // MARK: - Dependencies

    private weak var dashboardViewModel: DashboardViewModel?
    private let dbReader: DatabaseReader?
    private let taskWriter: TaskWriter?
    private let memoryStore: UserMemoryStore
    var geminiClient: GeminiClient?

    // MARK: - State

    var threads: [ChatThread] = []
    var activeThreadId: Int64?
    var messages: [ChatMessage] = []
    var isLoading = false
    var error: String?
    var isCreatingThread = false
    var isSummarizingThread = false

    /// Tracks message counts at last summary generation per thread.
    var threadSummaryMessageCounts: [Int64: Int] = [:]

    /// Set by ChatOverlayView to trigger a chat question.
    var pendingQuestion: String?

    /// Set to true to expand the chat overlay panel.
    var shouldExpandPanel = false

    /// Maximum number of chat messages to keep in memory per thread.
    private static let maxMessages = 50

    // MARK: - Init

    init(
        dashboardViewModel: DashboardViewModel,
        dbReader: DatabaseReader?,
        taskWriter: TaskWriter?,
        memoryStore: UserMemoryStore,
        geminiClient: GeminiClient?
    ) {
        self.dashboardViewModel = dashboardViewModel
        self.dbReader = dbReader
        self.taskWriter = taskWriter
        self.memoryStore = memoryStore
        self.geminiClient = geminiClient
    }

    // MARK: - Context Building (delegated to parent)

    /// Build conversation history for the AI (last 20 messages).
    func buildConversationHistory() -> [(role: String, content: String)] {
        messages.suffix(20).map { ($0.role.dbString, $0.content) }
    }

    /// Get context from the dashboard (tasks, activities, etc.).
    func getTaskContext() -> String {
        dashboardViewModel?.buildChatTaskContext() ?? "No activity recorded for this day."
    }

    /// Get memory context.
    func getMemoryContext() -> String? {
        memoryStore.contextString()
    }

    /// Get current screen name.
    var currentScreen: String {
        dashboardViewModel?.currentScreen ?? "Chat"
    }
}
