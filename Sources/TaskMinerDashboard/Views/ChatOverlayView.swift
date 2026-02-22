import SwiftUI
import AppKit
import TaskMinerShared

struct ChatOverlayView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var inputText = ""
    @State private var isExpanded = false

    /// Show the message panel when expanded AND there are messages or loading.
    private var showMessages: Bool {
        isExpanded && (!viewModel.chatMessages.isEmpty || viewModel.isChatLoading)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Message panel (slides up when expanded)
            if showMessages {
                messagePanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Input bar — always visible at the bottom
            inputBar
        }
        .background(
            RoundedRectangle(cornerRadius: showMessages ? 16 : 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 12, y: -4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: showMessages ? 16 : 12, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: showMessages ? 16 : 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.25), value: showMessages)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            if showMessages {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded = false
                    }
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }

            ChatTextField(
                text: $inputText,
                placeholder: "Ask about your day\u{2026}",
                onSubmit: sendMessage
            )
            .frame(height: 22)

            if viewModel.isChatLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 24, height: 24)
            } else {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            canSend ? Theme.accent : Theme.textQuaternary
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Message Panel

    private var messagePanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Chat")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)

                Spacer()

                Button {
                    viewModel.clearChat()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Clear chat")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Divider()
                .padding(.horizontal, 8)

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.chatMessages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if viewModel.isChatLoading {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                                Text("Thinking\u{2026}")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textMuted)
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                            .id("loading")
                        }

                        if let error = viewModel.chatError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.statusError)
                                Text(error)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                                Spacer()
                                Button {
                                    viewModel.chatError = nil
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textMuted)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(Theme.statusError.opacity(0.06))
                            .cornerRadius(8)
                            .id("error")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .onChange(of: viewModel.chatMessages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        if viewModel.isChatLoading {
                            proxy.scrollTo("loading", anchor: .bottom)
                        } else if let last = viewModel.chatMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.isChatLoading) { _, loading in
                    if loading {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("loading", anchor: .bottom)
                        }
                    }
                }
            }
            .frame(minHeight: 60, maxHeight: 300)

            Divider()
                .padding(.horizontal, 8)
        }
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

        // Always expand when sending — shows the loading indicator immediately
        if !isExpanded {
            withAnimation(.easeInOut(duration: 0.25)) { isExpanded = true }
        }
    }
}

// MARK: - AppKit TextField (reliable keyboard input on macOS)

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

            Text(message.content)
                .font(.system(size: 13))
                .foregroundStyle(message.role == .user ? .white : Theme.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.role == .user
                        ? AnyShapeStyle(Theme.accent)
                        : AnyShapeStyle(Theme.cardBackground)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    message.role == .assistant
                        ? RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                        : nil
                )

            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }
}
