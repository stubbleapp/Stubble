import SwiftUI
import AppKit
import TaskMinerShared

struct ChatOverlayView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @Environment(\.openWindow) private var openWindow
    @State private var inputText = ""
    @State private var isExpanded = false

    /// AI-generated suggestions preferred, with static fallback.
    private var activeSuggestions: [String] {
        if !viewModel.suggestedQuestions.isEmpty {
            return viewModel.suggestedQuestions
        }
        return [
            "Describe my day",
            "What did I work on?",
            "Summarize my projects",
            "Show time by app",
            "Any tips for tomorrow?"
        ]
    }

    private var activeThread: ChatThread? {
        guard let activeId = viewModel.activeThreadId else { return nil }
        return viewModel.chatThreads.first(where: { $0.id == activeId })
    }

    private var conversationTitle: String {
        if let thread = activeThread {
            let summary = thread.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty { return summary }

            let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // Hide legacy migration titles like "Chat 2026-..." in favor of neutral label.
            if title.hasPrefix("Chat ") || title == "New Chat" || title.isEmpty {
                return "Untitled Chat"
            }
            return title
        }
        return "New Chat"
    }

    private func threadChipTitle(_ thread: ChatThread) -> String {
        let summary = thread.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { return summary }

        let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix("Chat ") || title == "New Chat" || title.isEmpty {
            return "Untitled Chat"
        }
        return title
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Scrim — tap outside to close
            if isExpanded {
                Color.black.opacity(0.001)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            isExpanded = false
                        }
                        viewModel.notifyChatPanelCollapsed()
                    }
                    .transition(.opacity)
            }

            // Unified chat card — suggestion pills persist across states
            VStack(spacing: 0) {
                // Message panel revealed when expanded (clipped by container)
                if isExpanded {
                    messagePanelContent
                }

                // Suggestion pills — always present
                suggestionPills

                // Input bar
                if isExpanded {
                    expandedInputBar
                } else {
                    collapsedInputBar
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.chatSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.chatBorder, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 20, y: 0)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            .padding(.horizontal, 20)
            .padding(.top, isExpanded ? 24 : 0)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
        .onAppear {
            if viewModel.chatThreads.isEmpty {
                viewModel.loadChatThreads()
            }
        }
        .onChange(of: viewModel.pendingChatQuestion) { _, question in
            guard let question, !question.isEmpty else { return }
            // Always start a new chat when triggered from external sources (e.g. recommendation cards)
            viewModel.activeThreadId = nil
            viewModel.chatMessages = []
            inputText = question
            viewModel.pendingChatQuestion = nil
            sendMessage()
        }
        .onChange(of: viewModel.shouldExpandChatPanel) { _, shouldExpand in
            guard shouldExpand else { return }
            viewModel.shouldExpandChatPanel = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isExpanded = true
            }
        }
        .onChange(of: viewModel.currentScreen) { _, _ in
            // Collapse chat when switching tabs
            if isExpanded {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isExpanded = false
                }
                viewModel.notifyChatPanelCollapsed()
            }
        }
    }

    // MARK: - Collapsed Input Bar

    private var collapsedInputBar: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isExpanded = true }
        } label: {
            HStack(spacing: 10) {
                ActivityHaloDot(color: Theme.accent, size: 20)

                Text("Ask Stubble\u{2026}")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)

                Spacer()

                if viewModel.isChatLoading {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.textQuaternary.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open chat")
    }

    // MARK: - Expanded Input Bar

    private var expandedInputBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isExpanded = false
                }
                viewModel.notifyChatPanelCollapsed()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 24, height: 24)
                    .background(Theme.chatSeparator)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            ChatTextField(
                text: $inputText,
                placeholder: "Ask Stubble\u{2026}",
                onSubmit: sendMessage
            )
            .frame(height: 22)

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        canSend ? Theme.accent : Theme.textQuaternary.opacity(0.4)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Message Panel Content (header + messages, no suggestion pills)

    private var messagePanelContent: some View {
        VStack(spacing: 0) {
            // Header: title dropdown + action buttons
            HStack(spacing: 8) {
                // Title as dropdown (thread switcher)
                if viewModel.chatThreads.isEmpty {
                    Text(conversationTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                } else {
                    Menu {
                        ForEach(viewModel.chatThreads) { thread in
                            Button {
                                viewModel.switchToThread(thread.id)
                            } label: {
                                HStack {
                                    Text(threadChipTitle(thread))
                                        .lineLimit(1)
                                    if thread.id == viewModel.activeThreadId {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(conversationTitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: true, vertical: false)
                }

                Spacer()

                // New Chat
                Button {
                    viewModel.createNewChatThread()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Theme.chatSeparator)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isCreatingThread)
                .help("New chat")

                // Delete
                if activeThread != nil {
                    Button {
                        if let threadId = viewModel.activeThreadId {
                            viewModel.deleteThread(threadId)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(Theme.chatSeparator)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete chat")
                }

                // Close
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isExpanded = false
                    }
                    viewModel.notifyChatPanelCollapsed()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Theme.chatSeparator)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // Subtle separator
            Rectangle()
                .fill(Theme.chatSeparator)
                .frame(height: 0.5)
                .padding(.horizontal, 12)

            // Messages
            if viewModel.chatMessages.isEmpty && !viewModel.isChatLoading {
                Spacer(minLength: 0)
            } else {
                messagesScrollView
            }

            // Subtle separator
            Rectangle()
                .fill(Theme.chatSeparator)
                .frame(height: 0.5)
                .padding(.horizontal, 12)
        }
    }

    // MARK: - Suggestion Pills (horizontal scroll with refresh button)

    private var isLoadingSuggestions: Bool {
        viewModel.isGeneratingSuggestedQuestions
    }

    private var suggestionPills: some View {
        HStack(spacing: 0) {
            // Refresh button — spins while generating
            Button {
                viewModel.refreshSuggestedQuestions()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isLoadingSuggestions ? Theme.accent : Theme.textMuted)
                    .rotationEffect(.degrees(isLoadingSuggestions ? 360 : 0))
                    .animation(
                        isLoadingSuggestions
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: isLoadingSuggestions
                    )
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isLoadingSuggestions)
            .help(isLoadingSuggestions ? "Generating…" : "Refresh suggestions")
            .padding(.leading, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if isLoadingSuggestions {
                        // Skeleton loading pills
                        ForEach(0..<4, id: \.self) { _ in
                            SkeletonSuggestionPill()
                        }
                    } else {
                        ForEach(activeSuggestions, id: \.self) { suggestion in
                            Button {
                                // Always start a new chat when clicking a suggestion
                                viewModel.activeThreadId = nil
                                viewModel.chatMessages = []
                                inputText = suggestion
                                sendMessage()
                            } label: {
                                Text(suggestion)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 14)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Messages Scroll View

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Use a regular VStack instead of LazyVStack to avoid view recycling issues
                // during rapid scrolling while content is being streamed/mutated.
                VStack(spacing: 16) {
                    ForEach(viewModel.chatMessages) { message in
                        MessageBubble(
                            message: message,
                            onContentChange: {
                                // Scroll as streaming content arrives
                                scrollToBottom(proxy: proxy)
                            }
                        )
                        .id(message.id)
                    }

                    if let error = viewModel.chatError {
                        errorRow(error)
                            .id("error")
                    }

                    // Scroll anchor at the bottom
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onAppear {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.chatMessages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.isChatLoading) { _, loading in
                if loading {
                    scrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: isExpanded) { _, expanded in
                if expanded {
                    // Scroll to bottom when chat panel expands
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollToBottom(proxy: proxy)
                    }
                }
            }
        }
        .frame(minHeight: 60, maxHeight: .infinity)
    }

    // MARK: - Error Row

    /// Whether the error message indicates a proxy account issue (trial/session/rate limit).
    private func isAccountError(_ error: String) -> Bool {
        error.contains("trial has ended") || error.contains("session has expired") || error.contains("request limit")
    }

    private func errorRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.statusError.opacity(0.7))
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                Spacer()
                Button {
                    viewModel.chatError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }

            if isAccountError(error) {
                Button {
                    openWindow(id: "settings")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 9))
                        Text("Open Settings")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Theme.statusError.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Helpers

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isChatLoading
    }

    private func sendMessage() {
        guard canSend else { return }
        let text = inputText
        inputText = ""
        viewModel.sendChatMessage(text)

        if !isExpanded {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isExpanded = true }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

// MARK: - Skeleton Suggestion Pill

private struct SkeletonSuggestionPill: View {
    // Varying widths for visual interest
    private static let widths: [CGFloat] = [80, 100, 70, 90]
    @State private var width: CGFloat = 80

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.textMuted.opacity(0.15))
            .frame(width: width, height: 24)
            .shimmer(active: true)
            .onAppear {
                width = Self.widths.randomElement() ?? 80
            }
    }
}
