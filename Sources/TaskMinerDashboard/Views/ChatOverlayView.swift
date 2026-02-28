import SwiftUI
import AppKit
import TaskMinerShared

struct ChatOverlayView: View {
    @Environment(DashboardViewModel.self) var viewModel
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
            // Refresh button
            Button {
                viewModel.generateRecommendations()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Refresh suggestions")
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
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
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
    @State private var showCopied = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }

            if message.role == .user {
                userBubble
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    assistantContent

                    // Copy button below completed assistant responses
                    if !message.isStreaming && !message.content.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            showCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                showCopied = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9, weight: .medium))
                                if showCopied {
                                    Text("Copied")
                                        .font(.system(size: 10, weight: .medium))
                                }
                            }
                            .foregroundStyle(showCopied ? Theme.accent : Theme.textMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Theme.chatSeparator.opacity(showCopied ? 0 : 0.6))
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Copy response")
                        .animation(.easeInOut(duration: 0.2), value: showCopied)
                    }
                }
            }

            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }

    // MARK: - User Bubble (accent pill)

    private var userBubble: some View {
        Text(message.content)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .lineSpacing(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.accent)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.15), radius: 6, y: 2)
    }

    // MARK: - Assistant Content (block-based rendering, no container)

    private var assistantContent: some View {
        Group {
            if message.isStreaming && message.content.isEmpty {
                streamingDotsView
            } else if message.isStreaming {
                // Plain text while streaming for performance
                Text(message.content + "\u{258E}")
            } else {
                // Block-based markdown after completion
                let blocks = Self.parseBlocks(message.content)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(blocks) { block in
                        blockView(block)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textSecondary)
        .textSelection(.enabled)
        .lineSpacing(3)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock) -> some View {
        switch block.kind {
        case .paragraph(let text):
            Text(Self.inlineMarkdown(text))

        case .heading(let text):
            Text(Self.inlineMarkdown(text))
                .foregroundStyle(Theme.textPrimary)
                .fontWeight(.semibold)
                .padding(.top, 2)

        case .bullet(let text, let level):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(level == 0 ? "\u{2022}" : "\u{25E6}")
                    .foregroundStyle(Theme.accent)
                Text(Self.inlineMarkdown(text))
            }
            .padding(.leading, CGFloat(level) * 16)
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

    // MARK: - Block-Based Markdown Parsing

    /// Parse markdown source into structured blocks (paragraphs, bullets, headings).
    private static func parseBlocks(_ source: String) -> [ContentBlock] {
        guard !source.isEmpty else { return [] }

        var blocks: [ContentBlock] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var paragraphLines: [String] = []

        func flushParagraph() {
            let text = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(ContentBlock(kind: .paragraph(text)))
            }
            paragraphLines = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Blank line → paragraph break
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            // Heading (# / ## / ###)
            if let range = line.range(of: #"^#{1,3}\s+"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(ContentBlock(kind: .heading(String(line[range.upperBound...]))))
                continue
            }

            // Nested bullet (indented - or *)
            if let match = line.range(of: #"^(\s{2,}|\t)[\-\*]\s"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(ContentBlock(kind: .bullet(String(line[match.upperBound...]), level: 1)))
                continue
            }

            // Top-level bullet (- or *)
            if let match = line.range(of: #"^[\-\*]\s"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(ContentBlock(kind: .bullet(String(line[match.upperBound...]), level: 0)))
                continue
            }

            // Numbered list (1. 2. etc.)
            if let match = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(ContentBlock(kind: .bullet(String(line[match.upperBound...]), level: 0)))
                continue
            }

            // Regular text → accumulate into paragraph
            paragraphLines.append(line)
        }

        flushParagraph()
        return blocks
    }

    /// Parse inline markdown (bold, italic, code) into an AttributedString.
    private static func inlineMarkdown(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: 12, design: .monospaced)
            }
        }
        return attributed
    }
}

// MARK: - Content Block Model

private struct ContentBlock: Identifiable {
    let id = UUID()
    let kind: Kind

    enum Kind {
        case paragraph(String)
        case bullet(String, level: Int)
        case heading(String)
    }
}
