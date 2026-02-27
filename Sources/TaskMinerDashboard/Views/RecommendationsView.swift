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

                        // 2. Recommendations (horizontal scroll cards)
                        if !viewModel.recommendations.isEmpty {
                            recommendationCardsSection
                                .padding(.bottom, 16)
                        }

                        // 3. Suggested Questions
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
                    .font(Theme.headerFont(size: 24))
                    .foregroundStyle(Theme.textPrimary)

                if let context = viewModel.greetingContext {
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
}

// MARK: - Projects Expandable View

struct ProjectsExpandableView: View {
    let projects: [ProjectActivity]
    @State private var showAll = false
    @State private var expandedActivityID: UUID?
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
                    ProjectRow(activity: activity, expandedID: $expandedActivityID)
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

struct ProjectRow: View {
    let activity: ProjectActivity
    @Binding var expandedID: UUID?
    @Environment(DashboardViewModel.self) var viewModel

    private var isExpanded: Bool {
        expandedID == activity.id
    }

    private var activityColor: Color {
        Theme.barPalette[activity.colorIndex % Theme.barPalette.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedID = isExpanded ? nil : activity.id
                }
            } label: {
                HStack(spacing: 10) {
                    ActivityHaloDot(color: activityColor, size: 20)

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
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.primaryBackground.opacity(0.55))
                )
                .compositingGroup()
                .glassEffect(.regular, in: .rect(cornerRadius: 12, style: .continuous))
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
                .background(
                    Capsule()
                        .fill(Theme.primaryBackground.opacity(0.55))
                )
                .compositingGroup()
                .glassEffect(.regular, in: .capsule)
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
