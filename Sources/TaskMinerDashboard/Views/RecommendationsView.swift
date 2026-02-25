import SwiftUI
import AppKit
import TaskMinerShared

struct RecommendationsView: View {
    @Environment(DashboardViewModel.self) var viewModel

    /// The user's first name from macOS account, used for the greeting.
    private var firstName: String {
        let full = NSFullUserName()
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    /// Whether there's any content to show (recommendations or day summary).
    private var hasContent: Bool {
        !viewModel.recommendations.isEmpty || viewModel.daySummaryContent != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isGeneratingRecommendations && !hasContent {
                // Loading — full-screen centered
                Spacer()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Analyzing your recent activity\u{2026}")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            } else if !hasContent && !viewModel.hasAttemptedStubsGeneration {
                // Not yet attempted — blank, auto-load will fire via onAppear
                Spacer()
            } else if !hasContent {
                // Attempted but empty (no API key or no data)
                Spacer()
                VStack(spacing: 14) {
                    Text("Generate stubs to get personalized\ninsights based on your recent work.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    Button(action: { viewModel.generateRecommendations() }) {
                        Text("Generate Stubs")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .disabled(!viewModel.hasGeminiKey)
                    .opacity(viewModel.hasGeminiKey ? 1 : 0.4)

                    if !viewModel.hasGeminiKey {
                        Text("Requires a Gemini API key")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                Spacer()
            } else {
                // Populated — greeting, content, questions
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header — greeting + refresh
                        headerSection
                            .padding(.horizontal, 24)
                            .padding(.top, 20)
                            .padding(.bottom, 16)

                        // Error banner
                        if let error = viewModel.recommendationsError {
                            errorBanner(error)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                        }

                        // Day summary (past days only)
                        if let summary = viewModel.daySummaryContent {
                            daySummaryCard(summary)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                        }

                        // Insight rows
                        if !viewModel.recommendations.isEmpty {
                            insightsSection
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                        }

                        // Suggested questions — horizontal pills
                        if !viewModel.suggestedQuestions.isEmpty {
                            questionPills
                                .padding(.bottom, 16)
                        }

                        Spacer().frame(height: 64)
                    }
                }
            }
        }
        .onAppear {
            // Auto-generate stubs on first view if we have data and a key
            if !hasContent
                && !viewModel.isGeneratingRecommendations
                && !viewModel.hasAttemptedStubsGeneration
                && viewModel.hasGeminiKey
                && !viewModel.tasks.isEmpty {
                viewModel.hasAttemptedStubsGeneration = true
                viewModel.generateRecommendations()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hey, \(firstName)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                if let context = viewModel.greetingContext {
                    Text(context)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Button(action: { viewModel.generateRecommendations() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .symbolEffect(.bounce, value: viewModel.isGeneratingRecommendations)
                    .frame(width: 28, height: 28)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isGeneratingRecommendations)
            .help("Regenerate stubs")
            .accessibilityLabel("Regenerate stubs")
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.recommendationsError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.statusError.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Day Summary Card

    @ViewBuilder
    private func daySummaryCard(_ summary: String) -> some View {
        let rendered = Self.renderMarkdown(summary)
        VStack(alignment: .leading, spacing: 0) {
            if let attributed = rendered {
                Text(attributed)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Insights Section

    private var insightsSection: some View {
        VStack(spacing: 2) {
            ForEach(viewModel.recommendations) { tip in
                InsightRow(
                    tip: tip,
                    onDismiss: { viewModel.dismissRecommendation(id: tip.id) }
                )
            }
        }
    }

    // MARK: - Question Pills (horizontal scroll)

    private var questionPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.suggestedQuestions, id: \.self) { question in
                    Button {
                        viewModel.pendingChatQuestion = question
                    } label: {
                        Text(question)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Markdown Helpers

    /// Pre-process block-level markdown into inline equivalents, then parse.
    private static func renderMarkdown(_ source: String) -> AttributedString? {
        let processed = preprocessMarkdown(source)
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

    private static func preprocessMarkdown(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let str = String(line)
                if let match = str.range(of: #"^(\s{2,}|\t)[\-\*]\s"#, options: .regularExpression) {
                    let indent = str[str.startIndex..<str.index(before: match.upperBound)]
                    let rest = str[match.upperBound...]
                    let indentStr = String(indent)
                        .replacingOccurrences(of: "-", with: "\u{25E6}")
                        .replacingOccurrences(of: "*", with: "\u{25E6}")
                    return "\(indentStr) \(rest)"
                }
                if let range = str.range(of: #"^[\-\*]\s"#, options: .regularExpression) {
                    return "\u{2022}\u{2002}" + str[range.upperBound...]
                }
                if str.hasPrefix("## ") {
                    return "**" + str.dropFirst(3) + "**"
                }
                if str.hasPrefix("### ") {
                    return "**" + str.dropFirst(4) + "**"
                }
                return str
            }
            .joined(separator: "\n")
    }
}

// MARK: - Insight Row (single-line glass, hover reveals description)

private struct InsightRow: View {
    let tip: Recommendation
    let onDismiss: () -> Void
    @State private var isHovering = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Always-visible: icon + title
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: tip.iconName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 20)

                    Text(tip.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    // Dismiss — only on hover
                    if isHovering {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.textMuted.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textQuaternary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tip.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let urlStr = tip.actionURL,
                       let url = URL(string: urlStr) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 3) {
                                Text(tip.actionLabel)
                                    .font(.system(size: 11, weight: .medium))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                            .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.leading, 30) // Align with title text (past icon)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
