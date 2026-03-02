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
            "How much time on each project?",
            "What apps did I use most?",
            "Any tips for tomorrow?"
        ]
    }

    /// Derive a conversation title from the first user message.
    private var conversationTitle: String? {
        guard let firstUserMessage = viewModel.chatMessages.first(where: { $0.role == .user }) else {
            return nil
        }
        let text = firstUserMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= 40 { return text }
        let truncated = text.prefix(37)
        // Avoid cutting mid-word — find the last space
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[truncated.startIndex..<lastSpace]) + "…"
        }
        return String(truncated) + "…"
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
                    }
                    .transition(.opacity)
            }

            // Unified chat card — suggestion pills persist across states
            VStack(spacing: 0) {
                // Message panel slides in above the pills when expanded
                if isExpanded {
                    messagePanelContent
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Suggestion pills — always present, never re-rendered
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
            .padding(.bottom, 16)
            .fixedSize(horizontal: false, vertical: !isExpanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
        .onChange(of: viewModel.pendingChatQuestion) { _, question in
            guard let question, !question.isEmpty else { return }
            inputText = question
            viewModel.pendingChatQuestion = nil
            sendMessage()
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
            // Header
            HStack(spacing: 8) {
                ActivityHaloDot(color: Theme.accent, size: 14)

                if let title = conversationTitle {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                if !viewModel.chatMessages.isEmpty {
                    Button {
                        viewModel.clearChat()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(Theme.chatSeparator)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear chat")
                }

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isExpanded = false
                    }
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

    private var suggestionPills: some View {
        HStack(spacing: 0) {
            // Refresh button — spins while generating
            Button {
                viewModel.generateRecommendations()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(viewModel.isGeneratingRecommendations ? Theme.accent : Theme.textMuted)
                    .rotationEffect(.degrees(viewModel.isGeneratingRecommendations ? 360 : 0))
                    .animation(
                        viewModel.isGeneratingRecommendations
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: viewModel.isGeneratingRecommendations
                    )
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isGeneratingRecommendations)
            .help(viewModel.isGeneratingRecommendations ? "Generating…" : "Refresh suggestions")
            .padding(.leading, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(activeSuggestions, id: \.self) { suggestion in
                        Button {
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
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.chatMessages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if let error = viewModel.chatError {
                        errorRow(error)
                            .id("error")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: viewModel.chatMessages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.chatMessages.last?.content) { _, _ in
                if let last = viewModel.chatMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.isChatLoading) { _, loading in
                if loading {
                    scrollToBottom(proxy: proxy)
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
        withAnimation(.easeOut(duration: 0.2)) {
            if let last = viewModel.chatMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
