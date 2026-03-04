import SwiftUI
import MarkdownUI

// Alias to avoid conflict with MarkdownUI.Theme
private typealias AppTheme = Theme

/// A view that renders markdown text with streaming indicator.
struct StreamingMarkdownView: View {
    /// The full text content (updated as chunks arrive from the API).
    let content: String
    /// Whether the content is still streaming.
    let isStreaming: Bool
    /// Called when content changes (for scroll tracking).
    var onContentRevealed: (() -> Void)?

    var body: some View {
        Group {
            if content.isEmpty && isStreaming {
                streamingDotsView
            } else {
                Markdown(content)
                    .markdownTheme(chatTheme)
                    .markdownBlockStyle(\.paragraph) { configuration in
                        configuration.label
                            .lineSpacing(6)
                    }
            }
        }
        .textSelection(.enabled)
        .onChange(of: content) { _, _ in
            onContentRevealed?()
        }
    }

    // MARK: - Theme

    private var chatTheme: MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text {
                ForegroundColor(.primary)
                FontSize(13)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(11)
                BackgroundColor(AppTheme.chatSeparator.opacity(0.5))
            }
            .strong {
                FontWeight(.semibold)
            }
            .emphasis {
                FontStyle(.italic)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(15)
                        ForegroundColor(.primary)
                    }
                    .markdownMargin(top: 12, bottom: 8)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(14)
                        ForegroundColor(.primary)
                    }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(13)
                        ForegroundColor(.primary)
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 8, bottom: 8)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 16)
            }
            .codeBlock { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(11)
                    }
                    .padding(10)
                    .background(AppTheme.chatSeparator.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .markdownMargin(top: 8, bottom: 8)
            }
    }

    // MARK: - Streaming Dots

    private var streamingDotsView: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                StreamingDot(delay: Double(index) * 0.15)
            }
        }
        .frame(height: 16)
    }
}

/// Animated dot for streaming indicator
private struct StreamingDot: View {
    let delay: Double
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .fill(AppTheme.textMuted.opacity(0.6))
            .frame(width: 6, height: 6)
            .scaleEffect(isAnimating ? 1.0 : 0.5)
            .opacity(isAnimating ? 1.0 : 0.4)
            .animation(
                .easeInOut(duration: 0.5)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: isAnimating
            )
            .onAppear {
                isAnimating = true
            }
    }
}
