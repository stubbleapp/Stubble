import SwiftUI
import AppKit
import TaskMinerShared

struct RecommendationsView: View {
    @Environment(DashboardViewModel.self) var viewModel

    private var firstName: String {
        let full = NSFullUserName()
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    private var hasContent: Bool {
        !viewModel.recommendations.isEmpty
            || viewModel.daySummaryContent != nil
            || !viewModel.projectActivities.isEmpty
    }

    private var displaySummary: String? {
        viewModel.daySummaryContent ?? viewModel.daySummaryText
    }

    private var sortedProjects: [ProjectActivity] {
        viewModel.projectActivities.sorted { $0.totalDuration > $1.totalDuration }
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isGeneratingRecommendations && !hasContent {
                Spacer()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Analyzing your recent activity\u{2026}")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            } else if !hasContent {
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // 1. Header
                        headerSection
                            .padding(.horizontal, 24)
                            .padding(.top, 20)
                            .padding(.bottom, 16)

                        if let error = viewModel.recommendationsError {
                            errorBanner(error)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                        }

                        // 2. Day Summary
                        if let summary = displaySummary {
                            daySummaryCard(summary)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                        }

                        // 3. Top Projects
                        if !sortedProjects.isEmpty {
                            projectsSection
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                        }

                        // 4. Recommendations (horizontal scroll cards)
                        if viewModel.isViewingToday && !viewModel.recommendations.isEmpty {
                            recommendationCardsSection
                                .padding(.bottom, 16)
                        }

                        // 5. Suggested Questions
                        if viewModel.isViewingToday && !viewModel.suggestedQuestions.isEmpty {
                            questionPills
                                .padding(.bottom, 16)
                        }

                        Spacer().frame(height: 64)
                    }
                }
            }
        }
        .onAppear {
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
                if viewModel.isViewingToday {
                    Text("Hey, \(firstName)")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    Text(SharedFormatters.headerDateFormatter.string(from: viewModel.selectedDate))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                }

                // Only show the greeting context teaser for today —
                // past days have a full day summary card below instead.
                if viewModel.isViewingToday, let context = viewModel.greetingContext {
                    Text(context)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Button(action: { viewModel.generateRecommendations() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: viewModel.isGeneratingRecommendations)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent.opacity(0.08))
                    .clipShape(Circle())
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

    // MARK: - Projects Section

    private var projectsSection: some View {
        ProjectsExpandableView(projects: sortedProjects)
    }

    // MARK: - Recommendation Cards (horizontal scroll)

    private var recommendationCardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recommended")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.recommendations) { tip in
                        RecommendationCard(tip: tip, onDismiss: {
                            viewModel.dismissRecommendation(id: tip.id)
                        })
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollClipDisabled(true)
        }
    }

    // MARK: - Question Pills (horizontal scroll)

    private var questionPills: some View {
        FlowLayout(spacing: 8) {
            ForEach(viewModel.suggestedQuestions, id: \.self) { question in
                Button {
                    viewModel.pendingChatQuestion = question
                } label: {
                    Text(question)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .modifier(LiquidGlassPillModifier())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Markdown Helpers

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

// MARK: - Projects Expandable View

private struct ProjectsExpandableView: View {
    let projects: [ProjectActivity]
    @State private var showAll = false
    @Environment(DashboardViewModel.self) var viewModel

    private var visibleProjects: [ProjectActivity] {
        showAll ? projects : Array(projects.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Text("Activities")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(visibleProjects) { activity in
                    ProjectRow(activity: activity)
                }
            }

            if projects.count > 3 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAll.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(showAll ? "Show less" : "Show all \(projects.count) activities")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: showAll ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 10)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Single Project Row (expandable)

private struct ProjectRow: View {
    let activity: ProjectActivity
    @State private var isExpanded = false
    @Environment(DashboardViewModel.self) var viewModel

    private var activityColor: Color {
        Theme.barPalette[activity.colorIndex % Theme.barPalette.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(activityColor)
                        .frame(width: 4, height: 18)

                    Text(activity.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(formatDuration(activity.totalDuration * viewModel.activityDurationScale))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textQuaternary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !activity.summary.isEmpty {
                        Text(activity.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // App icons
                    if !activity.appNames.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(activity.appNames.prefix(6), id: \.self) { app in
                                HoverableAppIconView(
                                    appName: app,
                                    bundleId: viewModel.bundleId(forAppName: app),
                                    size: 18
                                )
                            }
                            if activity.appNames.count > 6 {
                                Text("+\(activity.appNames.count - 6)")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Theme.textMuted)
                                    .frame(width: 18, height: 18)
                                    .background(Theme.surfaceElevated)
                                    .clipShape(Circle())
                            }
                        }
                    }

                    // Time range
                    Text(formatTimeRange(start: activity.startTime, end: activity.endTime))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.horizontal, 12)
                .padding(.leading, 14)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.clear)
        )
    }
}

// MARK: - Recommendation Card (horizontal scroll item)

private struct RecommendationCard: View {
    let tip: Recommendation
    let onDismiss: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: tip.iconName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)

                Text(tip.category.displayName.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .tracking(0.5)

                Spacer()

                if isHovering {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.textMuted.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }

            Text(tip.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(tip.description)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .lineSpacing(1)

            Spacer(minLength: 0)

            if let urlStr = tip.actionURL, let url = URL(string: urlStr) {
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
        .padding(14)
        .frame(width: 220, height: 170, alignment: .topLeading)
        .modifier(LiquidGlassCardModifier())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Liquid Glass Card Modifier

struct LiquidGlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12, style: .continuous))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                )
        }
    }
}

struct LiquidGlassPillModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                )
        }
    }
}
