import SwiftUI
import AppKit

// MARK: - Content Block Model

struct ContentBlock: Identifiable {
    let id = UUID()
    let kind: Kind

    enum Kind {
        case paragraph(String)
        case bullet(String, level: Int)
        case heading(String)
    }
}

// MARK: - AppKit TextField (auto-focuses on creation)

struct ChatTextField: NSViewRepresentable {
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

struct MessageBubble: View {
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
    static func parseBlocks(_ source: String) -> [ContentBlock] {
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
    static func inlineMarkdown(_ text: String) -> AttributedString {
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
