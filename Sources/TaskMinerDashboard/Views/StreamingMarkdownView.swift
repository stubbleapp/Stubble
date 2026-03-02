import SwiftUI
import MarkdownUI

// Alias to avoid conflict with MarkdownUI.Theme
private typealias AppTheme = Theme

/// A view that renders streaming markdown text with character-by-character animation.
/// Text is buffered and revealed smoothly regardless of how chunks arrive from the API.
struct StreamingMarkdownView: View {
    /// The full text content (updated as chunks arrive from the API).
    let content: String
    /// Whether the content is still streaming.
    let isStreaming: Bool
    /// Called when revealed content changes (for scroll tracking).
    var onContentRevealed: (() -> Void)?

    /// The portion of text currently revealed (animated).
    @State private var revealedCount: Int = 0
    /// Display link for smooth animation.
    @State private var displayLink: CVDisplayLink?
    /// Last update time for frame-rate independent animation.
    @State private var lastUpdateTime: CFTimeInterval = 0

    /// Characters revealed per second.
    private let charsPerSecond: Double = 150

    private var revealedText: String {
        if revealedCount >= content.count {
            return content
        }
        let safeCount = min(revealedCount, content.count)
        let index = content.index(content.startIndex, offsetBy: safeCount)
        return String(content[..<index])
    }

    private var isFullyRevealed: Bool {
        revealedCount >= content.count
    }

    var body: some View {
        Group {
            if content.isEmpty && isStreaming {
                streamingDotsView
            } else if isStreaming && !isFullyRevealed {
                // Streaming: show revealed text with cursor
                Markdown(revealedText + "\u{258E}")
                    .markdownTheme(chatTheme)
            } else {
                // Complete: full markdown rendering
                Markdown(content)
                    .markdownTheme(chatTheme)
            }
        }
        .textSelection(.enabled)
        .onAppear {
            if isStreaming && !content.isEmpty {
                startAnimation()
            } else if !isStreaming {
                revealedCount = content.count
            }
        }
        .onChange(of: content) { oldValue, newValue in
            // New content arrived
            if isStreaming && displayLink == nil && !newValue.isEmpty {
                startAnimation()
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming {
                stopAnimation()
                revealedCount = content.count
            }
        }
        .onChange(of: revealedCount) { _, _ in
            onContentRevealed?()
        }
        .onDisappear {
            stopAnimation()
        }
    }

    // MARK: - Animation using Timer (simpler, works on main thread)

    private func startAnimation() {
        guard displayLink == nil else { return }
        lastUpdateTime = CACurrentMediaTime()

        // Use a simple Timer on the main run loop
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            let now = CACurrentMediaTime()
            let delta = now - lastUpdateTime
            lastUpdateTime = now

            let charsToReveal = Int(delta * charsPerSecond)
            if charsToReveal > 0 && revealedCount < content.count {
                revealedCount = min(revealedCount + max(1, charsToReveal), content.count)
            }

            // Stop when fully revealed and not streaming
            if revealedCount >= content.count && !isStreaming {
                timer.invalidate()
            }
        }
    }

    private func stopAnimation() {
        // Timer will auto-stop via the invalidate in the timer block
    }

    // MARK: - Theme

    private var chatTheme: MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text {
                ForegroundColor(Color(AppTheme.textSecondary))
                FontSize(12)
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
                        FontSize(14)
                        ForegroundColor(Color(AppTheme.textPrimary))
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(13)
                        ForegroundColor(Color(AppTheme.textPrimary))
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(12)
                        ForegroundColor(Color(AppTheme.textPrimary))
                    }
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 4)
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
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AppTheme.textMuted.opacity(0.5))
                    .frame(width: 5, height: 5)
                    .scaleEffect(1.0)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: UUID()
                    )
            }
        }
        .frame(height: 14)
        .onAppear {} // Trigger animation
    }
}
