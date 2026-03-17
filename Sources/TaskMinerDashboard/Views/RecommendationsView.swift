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
            if !hasContent {
                // Show error if generation failed, otherwise show loading spinner
                Spacer()
                if let error = viewModel.recommendationsError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.textMuted)
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textMuted)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            viewModel.generateRecommendations()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Generating recommendations…")
                            .font(.system(size: 13))
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

                        Spacer().frame(height: 100)
                    }
                }
            }
        }
        .onAppear {
            // Auto-generate when visiting and none exist
            if !hasContent && !viewModel.isGeneratingRecommendations {
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

    // MARK: - Recommendation List

    private var recommendationCardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recommended")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 24)

            VStack(spacing: 8) {
                ForEach(viewModel.recommendations) { tip in
                    RecommendationRow(tip: tip, onDismiss: {
                        viewModel.dismissRecommendation(id: tip.id)
                    })
                }
            }
            .padding(.horizontal, 24)
        }
    }

}

// MARK: - Single Project Row (expandable)

struct ProjectRow: View {
    let activity: ProjectActivity
    @Binding var expandedID: UUID?
    var onTap: (() -> Void)? = nil
    @Environment(DashboardViewModel.self) var viewModel

    private var isExpanded: Bool {
        expandedID == activity.id
    }

    private var activityColor: Color {
        viewModel.resolvedColor(for: activity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let onTap = onTap {
                    onTap()
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedID = isExpanded ? nil : activity.id
                    }
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

// MARK: - Recommendation Row (list item)

struct RecommendationRow: View {
    let tip: Recommendation
    let onDismiss: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            Image(systemName: tip.iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Category label
                Text(tip.category.displayName.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .tracking(0.5)

                // Title
                Text(tip.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Description
                Text(tip.description)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .lineSpacing(1)

                // Reason
                if !tip.reason.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.accent.opacity(0.7))
                        Text(tip.reason)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(2)
                    }
                    .padding(.top, 2)
                }

                // Action button
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
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)

            // Dismiss button (always rendered, opacity controlled by hover)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textMuted.opacity(0.6))
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.cardBackground)
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
