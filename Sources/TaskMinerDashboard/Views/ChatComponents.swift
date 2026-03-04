import SwiftUI
import AppKit
import MarkdownUI

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
    /// Called when streaming content changes (for scroll tracking).
    var onContentChange: (() -> Void)?
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

    // MARK: - Assistant Content (streaming markdown)

    private var assistantContent: some View {
        StreamingMarkdownView(
            content: message.content,
            isStreaming: message.isStreaming,
            onContentRevealed: onContentChange
        )
        .padding(.vertical, 8)
    }
}
