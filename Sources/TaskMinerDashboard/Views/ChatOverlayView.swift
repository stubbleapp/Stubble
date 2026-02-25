import SwiftUI
import AppKit
import TaskMinerShared

struct ChatOverlayView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var inputText = ""
    @State private var isExpanded = false

    /// Quick-action suggestions shown when chat is expanded with no messages.
    private static let suggestions = [
        "Describe my day",
        "What did I work on?",
        "How much time on each project?",
        "What apps did I use most?",
        "Any tips for tomorrow?"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Message panel (slides up when expanded)
            if isExpanded {
                messagePanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Input bar — collapsed: tappable placeholder, expanded: real text field
            if isExpanded {
                expandedInputBar
            } else {
                collapsedInputBar
            }
        }
        .background(
            RoundedRectangle(cornerRadius: isExpanded ? 20 : 14, style: .continuous)
                .fill(.white.opacity(0.88))
                .shadow(color: .black.opacity(0.06), radius: 20, y: -6)
                .shadow(color: .black.opacity(0.04), radius: 6, y: -2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isExpanded ? 20 : 14, style: .continuous)
                .strokeBorder(.white.opacity(0.5), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 20 : 14, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .fixedSize(horizontal: false, vertical: true)
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
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent.opacity(0.7))

                Text("Ask about your day\u{2026}")
                    .font(.system(size: 13))
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
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            ChatTextField(
                text: $inputText,
                placeholder: "Ask about your day\u{2026}",
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

    // MARK: - Message Panel

    private var messagePanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent.opacity(0.6))

                Text("Chat")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)

                Spacer()

                if !viewModel.chatMessages.isEmpty {
                    Button {
                        viewModel.clearChat()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(.ultraThinMaterial)
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
                        .background(.ultraThinMaterial)
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
                .fill(Color.black.opacity(0.04))
                .frame(height: 0.5)
                .padding(.horizontal, 12)

            // Messages or suggestions
            if viewModel.chatMessages.isEmpty && !viewModel.isChatLoading {
                suggestionsPanel
            } else {
                messagesScrollView
            }

            // Subtle separator
            Rectangle()
                .fill(Color.black.opacity(0.04))
                .frame(height: 0.5)
                .padding(.horizontal, 12)
        }
    }

    // MARK: - Suggestions Panel

    private var suggestionsPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button {
                    inputText = suggestion
                    sendMessage()
                } label: {
                    HStack(spacing: 8) {
                        Text(suggestion)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)

                        Spacer()

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textQuaternary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SuggestionButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Messages Scroll View

    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
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
        .frame(minHeight: 60, maxHeight: 300)
    }

    // MARK: - Error Row

    private func errorRow(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.statusError.opacity(0.7))
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
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

// MARK: - Suggestion Button Style (hover highlight)

private struct SuggestionButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.black.opacity(0.03) : Color.clear)
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
    }
}

// MARK: - AppKit TextField (auto-focuses on creation)

private struct ChatTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true

        // Auto-focus after the expansion animation settles
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ChatTextField

        init(_ parent: ChatTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                      doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            Group {
                if message.isStreaming && message.content.isEmpty {
                    streamingDotsView
                } else if message.role == .assistant {
                    assistantContentView
                } else {
                    Text(message.content)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(message.role == .user ? .white : Theme.textPrimary)
            .textSelection(.enabled)
            .lineSpacing(3)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                message.role == .assistant
                    ? RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5)
                    : nil
            )
            .shadow(
                color: message.role == .user ? Theme.accent.opacity(0.15) : .black.opacity(0.03),
                radius: message.role == .user ? 6 : 3,
                y: 2
            )

            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.role == .user {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.accent)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.7))
        }
    }

    /// Assistant text — plain text during streaming for performance, markdown after completion.
    @ViewBuilder
    private var assistantContentView: some View {
        if message.isStreaming {
            Text(message.content + "\u{258E}")
                .foregroundStyle(Theme.textPrimary)
        } else if let rendered = markdownText(message.content) {
            Text(rendered)
        } else {
            Text(message.content)
        }
    }

    /// Animated dots shown while waiting for the first streaming chunk.
    private var streamingDotsView: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Theme.textMuted.opacity(0.5))
                    .frame(width: 5, height: 5)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: true
                    )
                    .onAppear {}
            }
        }
        .frame(height: 14)
    }

    private static func preprocessMarkdown(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let str = String(line)
                if let match = str.range(of: #"^(\s{2,}|\t)[\-\*]\s"#, options: .regularExpression) {
                    let indent = str[str.startIndex..<str.index(before: match.upperBound)]
                    let rest = str[match.upperBound...]
                    let indentStr = String(indent).replacingOccurrences(of: "-", with: "\u{25E6}").replacingOccurrences(of: "*", with: "\u{25E6}")
                    return "\(indentStr) \(rest)"
                }
                if let range = str.range(of: #"^[\-\*]\s"#, options: .regularExpression) {
                    return "\u{2022}\u{2002}" + str[range.upperBound...]
                }
                if let range = str.range(of: #"^#{1,3}\s+"#, options: .regularExpression) {
                    return "**" + str[range.upperBound...] + "**"
                }
                return str
            }
            .joined(separator: "\n")
    }

    private func markdownText(_ source: String) -> AttributedString? {
        guard !source.isEmpty else { return nil }
        let processed = Self.preprocessMarkdown(source)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var attributed = try? AttributedString(markdown: processed, options: options) else {
            return nil
        }
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                let range = run.range
                attributed[range].font = .system(size: 13, design: .monospaced)
            }
        }
        return attributed
    }
}
