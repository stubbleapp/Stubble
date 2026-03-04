import SwiftUI
import TaskMinerShared

/// Detail sheet for a project showing work patterns and AI-generated recommendations.
struct ProjectDetailSheet: View {
    let project: AggregatedProject
    @Environment(DashboardViewModel.self) var viewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isLoadingAnalysis = false

    private var analysis: ProjectAnalysis? {
        viewModel.cachedProjectAnalysis(for: project)
    }

    private var summary: String {
        viewModel.projectSummary(for: project)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Summary
                    if !summary.isEmpty {
                        summarySection
                    }

                    // Time metrics
                    metricsSection

                    // Work patterns
                    workPatternsSection

                    // Apps used
                    if !project.appNames.isEmpty {
                        appsSection
                    }

                    // AI Recommendations
                    recommendationsSection

                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, 20)
            }
        }
        .frame(minWidth: 440, idealWidth: 500, minHeight: 520, idealHeight: 640)
        .background(Theme.primaryBackground)
        .task {
            await loadAnalysisIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ActivityHaloDot(color: project.color, size: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(dateRangeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
    }

    private var dateRangeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"

        let start = formatter.string(from: project.firstActiveDate)
        let end = formatter.string(from: project.lastActiveDate)

        if start == end {
            return start
        }
        return "\(start) – \(end)"
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textMuted)

            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LiquidGlassCardModifier())
    }

    // MARK: - Metrics Section

    private var metricsSection: some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]

        return LazyVGrid(columns: columns, spacing: 10) {
            MetricCard(
                label: "Total Time",
                value: formatDuration(project.totalDuration),
                icon: "clock"
            )

            MetricCard(
                label: "Days Active",
                value: "\(project.daysActive)",
                icon: "calendar"
            )

            MetricCard(
                label: "Avg/Day",
                value: formatDuration(project.averageDailyDuration),
                icon: "chart.bar"
            )
        }
    }

    // MARK: - Work Patterns Section

    private var workPatternsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Work Patterns")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textMuted)

            // Weekday distribution
            weekdayChart

            // Hourly distribution
            hourlyChart

            // Daily sparkline
            dailySparkline
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LiquidGlassCardModifier())
    }

    private var weekdayChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By Day of Week")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textMuted)

            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { weekday in
                    let duration = project.weekdayDistribution[weekday] ?? 0
                    let maxDuration = project.weekdayDistribution.values.max() ?? 1

                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(project.color.opacity(duration > 0 ? 0.7 : 0.15))
                            .frame(height: barHeight(duration: duration, maxDuration: maxDuration, maxHeight: 30))
                            .frame(height: 30, alignment: .bottom)

                        Text(weekdayLabel(weekday))
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var hourlyChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By Hour")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textMuted)

            HStack(spacing: 1) {
                ForEach(0..<24, id: \.self) { hour in
                    let duration = project.hourlyDistribution[hour] ?? 0
                    let maxDuration = project.hourlyDistribution.values.max() ?? 1
                    let intensity = maxDuration > 0 ? duration / maxDuration : 0

                    Rectangle()
                        .fill(project.color.opacity(0.15 + intensity * 0.7))
                        .frame(height: 16)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            HStack {
                Text("12am")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.textQuaternary)
                Spacer()
                Text("12pm")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.textQuaternary)
                Spacer()
                Text("11pm")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.textQuaternary)
            }
        }
    }

    private var dailySparkline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Daily Activity")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textMuted)

            let sortedDaily = project.dailyDurations.sorted { $0.key < $1.key }
            let maxDuration = sortedDaily.map(\.value).max() ?? 1

            HStack(spacing: 2) {
                ForEach(sortedDaily, id: \.key) { date, duration in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(project.color.opacity(0.7))
                            .frame(height: barHeight(duration: duration, maxDuration: maxDuration, maxHeight: 24))
                            .frame(height: 24, alignment: .bottom)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Apps Section

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apps Used")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textMuted)

            FlowLayout(spacing: 8) {
                ForEach(project.appNames.sorted(), id: \.self) { appName in
                    AppIconView(bundleId: viewModel.bundleId(forAppName: appName), appName: appName, size: 24)
                        .help(appName)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LiquidGlassCardModifier())
    }

    // MARK: - Recommendations Section

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recommendations")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)

                Spacer()

                if isLoadingAnalysis || viewModel.isGeneratingProjectAnalysis {
                    ProgressView()
                        .scaleEffect(0.5)
                }
            }

            if let analysis = analysis {
                // Insights
                if !analysis.insights.isEmpty {
                    Text(analysis.insights)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(2)
                        .padding(.bottom, 4)
                }

                // Recommendations
                ForEach(analysis.recommendations) { rec in
                    ProjectRecommendationRow(recommendation: rec)
                }

                // Next Steps
                if !analysis.nextSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Next Steps")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.top, 6)

                        ForEach(analysis.nextSteps, id: \.self) { step in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.top, 2)

                                Text(step)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            } else if !isLoadingAnalysis && !viewModel.isGeneratingProjectAnalysis {
                // Not loaded yet and not loading
                Button {
                    Task { await loadAnalysisIfNeeded() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                        Text("Generate recommendations")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.hasGeminiKey)
                .opacity(viewModel.hasGeminiKey ? 1 : 0.5)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LiquidGlassCardModifier())
    }

    // MARK: - Helpers

    private func loadAnalysisIfNeeded() async {
        guard analysis == nil else { return }
        guard viewModel.hasGeminiKey else { return }

        isLoadingAnalysis = true
        await viewModel.generateProjectAnalysis(for: project)
        isLoadingAnalysis = false
    }

    private func barHeight(duration: TimeInterval, maxDuration: TimeInterval, maxHeight: CGFloat) -> CGFloat {
        guard maxDuration > 0 else { return 4 }
        let normalized = duration / maxDuration
        return max(4, CGFloat(normalized) * maxHeight)
    }

    private func weekdayLabel(_ weekday: Int) -> String {
        ["", "S", "M", "T", "W", "T", "F", "S"][weekday]
    }
}

// MARK: - Metric Card

private struct MetricCard: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textMuted)

                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .tracking(0.3)
            }

            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Project Recommendation Row

private struct ProjectRecommendationRow: View {
    let recommendation: ProjectRecommendation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: recommendation.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 20, height: 20)
                .background(Theme.accent.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(recommendation.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                Text(recommendation.description)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .lineSpacing(1)

                if let urlStr = recommendation.actionURL, let url = URL(string: urlStr) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 3) {
                            Text("Learn more")
                                .font(.system(size: 10, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

