import SwiftUI
import TaskMinerShared

struct HabitsView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var showAllPatterns = false
    @State private var showAllSuggestions = false
    @State private var showDetailedStats = false

    private var hasContent: Bool {
        viewModel.habitsAnalysis != nil || viewModel.habitsSnapshot != nil
    }

    /// Cached check for sufficient data (loaded async by ViewModel).
    private var hasSufficientData: Bool {
        viewModel.habitsHasSufficientData ?? false
    }

    /// Still loading the data check.
    private var isCheckingData: Bool {
        viewModel.habitsHasSufficientData == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if isCheckingData || (viewModel.isGeneratingHabits && !hasContent) {
                Spacer()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(isCheckingData ? "Loading\u{2026}" : "Analyzing your work patterns\u{2026}")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            } else if !hasSufficientData {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.textMuted.opacity(0.5))

                    Text("Habits needs at least one full day\nof activity to identify patterns.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    Text("Check back tomorrow.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textQuaternary)
                }
                Spacer()
            } else if !hasContent {
                Spacer()
                VStack(spacing: 14) {
                    Text("Discover your work habits and\nget personalized improvement tips.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    Button(action: { viewModel.generateHabits() }) {
                        Text("Analyze Habits")
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

                        if let error = viewModel.habitsError {
                            errorBanner(error)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                        }

                        // 2. Summary card
                        if let analysis = viewModel.habitsAnalysis, !analysis.summary.isEmpty {
                            summaryCard(analysis.summary)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                        }

                        // 3. Quick stats grid
                        if let snapshot = viewModel.habitsSnapshot {
                            statsSection(snapshot)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                        }

                        // 4. Habit insights
                        if let habits = viewModel.habitsAnalysis?.habits, !habits.isEmpty {
                            habitsSection(habits)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                        }

                        // 5. Improvement suggestions
                        if let improvements = viewModel.habitsAnalysis?.improvements, !improvements.isEmpty {
                            improvementsSection(improvements)
                                .padding(.bottom, 16)
                        }

                        Spacer().frame(height: 100)
                    }
                }
            }
        }
        .onAppear {
            // Kick off async data check if not yet done
            viewModel.checkHasSufficientData()
        }
        .onChange(of: viewModel.habitsHasSufficientData) { _, hasSufficient in
            // Auto-generate once data check completes and conditions are met
            if hasSufficient == true
                && !hasContent
                && !viewModel.isGeneratingHabits
                && !viewModel.hasAttemptedHabitsGeneration
                && viewModel.hasGeminiKey {
                viewModel.hasAttemptedHabitsGeneration = true
                viewModel.generateHabits()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Habits")
                    .font(Theme.headerFont(size: 24))
                    .foregroundStyle(Theme.textPrimary)

                if let snapshot = viewModel.habitsSnapshot {
                    Text("Based on \(snapshot.totalDaysAnalyzed) days of activity")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
            }

            Spacer()

            Button(action: {
                viewModel.hasAttemptedHabitsGeneration = true
                viewModel.generateHabits()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: viewModel.isGeneratingHabits)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isGeneratingHabits)
            .help("Refresh habits analysis")
            .accessibilityLabel("Refresh habits analysis")
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
                viewModel.habitsError = nil
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

    // MARK: - Summary Card

    private func summaryCard(_ summary: String) -> some View {
        Text(summary)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LiquidGlassCardModifier())
    }

    // MARK: - Quick Stats Grid

    private func statsSection(_ snapshot: HabitsDataSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showDetailedStats.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text("Key Metrics")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(showDetailedStats ? "Hide details" : "Show details")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Image(systemName: showDetailedStats ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                compactStatPill(
                    title: "Deep Work",
                    value: "\(Int(snapshot.deepWorkRatio * 100))%"
                )
                compactStatPill(
                    title: "Avg Focus",
                    value: "\(Int(snapshot.avgFocusDurationMinutes))m"
                )
                compactStatPill(
                    title: "Daily Active",
                    value: String(format: "%.1fh", snapshot.avgDailyActiveHours)
                )
            }

            if showDetailedStats {
                quickStatsGrid(snapshot)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func compactStatPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.selectedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
        )
    }

    private func quickStatsGrid(_ snapshot: HabitsDataSnapshot) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]

        return LazyVGrid(columns: columns, spacing: 12) {
            QuickStatCard(
                title: "Deep Work",
                value: "\(Int(snapshot.deepWorkRatio * 100))%",
                subtitle: "of active time",
                icon: "brain.head.profile",
                color: .purple
            )
            QuickStatCard(
                title: "Avg Focus",
                value: "\(Int(snapshot.avgFocusDurationMinutes))m",
                subtitle: "before switching",
                icon: "scope",
                color: .blue
            )
            QuickStatCard(
                title: "Daily Active",
                value: String(format: "%.1fh", snapshot.avgDailyActiveHours),
                subtitle: "average",
                icon: "clock",
                color: .teal
            )
            QuickStatCard(
                title: "Switches/hr",
                value: String(format: "%.1f", snapshot.avgAppSwitchesPerHour),
                subtitle: "app changes",
                icon: "arrow.triangle.swap",
                color: .orange
            )
        }
    }

    // MARK: - Habits Section

    private func habitsSection(_ habits: [HabitInsight]) -> some View {
        let visibleHabits = showAllPatterns ? habits : Array(habits.prefix(3))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Patterns")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if habits.count > 3 {
                    Button(showAllPatterns ? "Show less" : "Show all (\(habits.count))") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAllPatterns.toggle()
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                }
            }

            VStack(spacing: 10) {
                ForEach(visibleHabits) { habit in
                    HabitInsightCard(habit: habit)
                }
            }
        }
    }

    // MARK: - Improvements Section

    private func improvementsSection(_ improvements: [ImprovementSuggestion]) -> some View {
        let visibleSuggestions = showAllSuggestions ? improvements : Array(improvements.prefix(3))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Suggestions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if improvements.count > 3 {
                    Button(showAllSuggestions ? "Show less" : "Show all (\(improvements.count))") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAllSuggestions.toggle()
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)

            VStack(spacing: 10) {
                ForEach(visibleSuggestions) { suggestion in
                    ImprovementCard(suggestion: suggestion)
                        .padding(.horizontal, 24)
                }
            }
        }
    }
}

// MARK: - Quick Stat Card

private struct QuickStatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.accent)

                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .tracking(0.3)
            }

            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LiquidGlassCardModifier())
    }
}

// MARK: - Habit Insight Card

private struct HabitInsightCard: View {
    let habit: HabitInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: habit.iconName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(habit.category.color)

                Text(habit.category.displayName.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(habit.category.color)
                    .tracking(0.5)

                Spacer()

                if let trend = habit.trend {
                    trendBadge(trend)
                }
            }

            Text(habit.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(habit.dataPoint)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.accent)

            Text(habit.description)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LiquidGlassCardModifier())
    }

    private func trendBadge(_ trend: HabitInsight.Trend) -> some View {
        HStack(spacing: 2) {
            Image(systemName: trendIcon(trend))
                .font(.system(size: 8, weight: .bold))
            Text(trend.rawValue.capitalized)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(trendColor(trend))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(trendColor(trend).opacity(0.1))
        .clipShape(Capsule())
    }

    private func trendIcon(_ trend: HabitInsight.Trend) -> String {
        switch trend {
        case .improving: return "arrow.up.right"
        case .declining: return "arrow.down.right"
        case .stable: return "minus"
        }
    }

    private func trendColor(_ trend: HabitInsight.Trend) -> Color {
        switch trend {
        case .improving: return .green
        case .declining: return .red
        case .stable: return Color(white: 0.5)
        }
    }
}

// MARK: - Improvement Card (horizontal scroll item)

private struct ImprovementCard: View {
    let suggestion: ImprovementSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: suggestion.iconName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(suggestion.category.color)

                Text(suggestion.category.displayName.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .tracking(0.5)

                Spacer()

                Text(suggestion.impact.displayName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(suggestion.impact.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(suggestion.impact.color.opacity(0.12))
                    .clipShape(Capsule())
            }

            Text(suggestion.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(suggestion.description)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(3)
                .lineSpacing(1)

            Spacer(minLength: 0)

            if let related = suggestion.relatedHabit {
                Text("Related: \(related)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(LiquidGlassCardModifier())
    }
}
