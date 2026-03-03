import SwiftUI
import TaskMinerShared

struct HabitsView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var showFullAnalysis = false

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
                // Simplified "Weekly Focus Card" view
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header
                        headerSection
                            .padding(.horizontal, 24)
                            .padding(.top, 20)

                        if let error = viewModel.habitsError {
                            errorBanner(error)
                                .padding(.horizontal, 24)
                        }

                        // Focus Score Card (primary)
                        if let focusScore = viewModel.focusScore {
                            FocusScoreCard(score: focusScore)
                                .padding(.horizontal, 24)
                        }

                        // Today's Tip (actionable)
                        if let tip = viewModel.todayTip {
                            TodayTipCard(tip: tip) {
                                viewModel.dismissTip(tip.id)
                            }
                            .padding(.horizontal, 24)
                        }

                        // Weekly Sparkline (context)
                        if let bars = viewModel.weeklyBars {
                            WeekSparkline(bars: bars)
                                .padding(.horizontal, 24)
                        }

                        // "See full analysis" link
                        Button {
                            showFullAnalysis = true
                        } label: {
                            HStack(spacing: 6) {
                                Text("See full analysis")
                                    .font(.system(size: 13, weight: .medium))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                        Spacer().frame(height: 100)
                    }
                }
            }
        }
        .onAppear {
            viewModel.checkHasSufficientData()
            viewModel.loadWeeklyBars()
        }
        .onChange(of: viewModel.habitsHasSufficientData) { _, hasSufficient in
            if hasSufficient == true
                && !hasContent
                && !viewModel.isGeneratingHabits
                && !viewModel.hasAttemptedHabitsGeneration
                && viewModel.hasGeminiKey {
                viewModel.hasAttemptedHabitsGeneration = true
                viewModel.generateHabits()
            }
        }
        .sheet(isPresented: $showFullAnalysis) {
            HabitsDetailSheet()
                .environment(viewModel)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This Week")
                    .font(Theme.headerFont(size: 20))
                    .foregroundStyle(Theme.textPrimary)

                if let snapshot = viewModel.habitsSnapshot {
                    Text("Based on \(snapshot.totalDaysAnalyzed) days")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
            }

            Spacer()

            Button(action: {
                viewModel.hasAttemptedHabitsGeneration = true
                viewModel.generateHabits()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .symbolEffect(.bounce, value: viewModel.isGeneratingHabits)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceElevated)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isGeneratingHabits)
            .help("Refresh habits analysis")
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
}

// MARK: - Focus Score Card

private struct FocusScoreCard: View {
    let score: FocusScore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title
            Text("FOCUS SCORE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .tracking(0.5)

            // Score + Progress bar
            HStack(spacing: 16) {
                // Percentage
                Text("\(score.percentage)%")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(score.scoreColor)

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.surfaceElevated)
                            .frame(height: 8)

                        // Fill
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(score.scoreColor)
                            .frame(width: geometry.size.width * score.value, height: 8)
                    }
                }
                .frame(height: 8)
            }

            // Trend + Insight
            HStack(spacing: 6) {
                // Trend badge
                if score.trendDelta != 0 {
                    HStack(spacing: 2) {
                        Image(systemName: score.trend.icon)
                            .font(.system(size: 9, weight: .bold))
                        Text(score.trendDelta > 0 ? "+\(score.trendDelta)%" : "\(score.trendDelta)%")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(score.trend.color)
                }

                // Separator dot
                if score.trendDelta != 0 && !score.insight.isEmpty {
                    Circle()
                        .fill(Theme.textQuaternary)
                        .frame(width: 3, height: 3)
                }

                // Insight
                Text(score.insight)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LiquidGlassCardModifier())
    }
}

// MARK: - Today's Tip Card

private struct TodayTipCard: View {
    let tip: ImprovementSuggestion
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.yellow)

                Text("TODAY'S TIP")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .tracking(0.5)

                Spacer()

                // Impact badge
                Text(tip.impact.displayName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tip.impact.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tip.impact.color.opacity(0.12))
                    .clipShape(Capsule())
            }

            // Tip content
            Text(tip.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Description (abbreviated)
            Text(tip.description)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .lineSpacing(1)

            // "Got it" button
            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Text("Got it")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LiquidGlassCardModifier())
    }
}

// MARK: - Week Sparkline

private struct WeekSparkline: View {
    let bars: [DailyActivityBar]

    private var maxHours: Double {
        bars.map(\.hours).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THIS WEEK")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .tracking(0.5)

            HStack(spacing: 8) {
                ForEach(bars) { bar in
                    VStack(spacing: 4) {
                        // Bar
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(bar.isToday ? Theme.accent : Theme.surfaceElevated)
                            .frame(width: 28, height: barHeight(for: bar))

                        // Day label
                        Text(bar.dayLabel)
                            .font(.system(size: 10, weight: bar.isToday ? .semibold : .regular))
                            .foregroundStyle(bar.isToday ? Theme.accent : Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 60)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LiquidGlassCardModifier())
    }

    private func barHeight(for bar: DailyActivityBar) -> CGFloat {
        guard maxHours > 0 else { return 4 }
        let normalized = bar.hours / maxHours
        return max(4, CGFloat(normalized) * 40)
    }
}

// MARK: - Habits Detail Sheet (Full Analysis)

private struct HabitsDetailSheet: View {
    @Environment(DashboardViewModel.self) var viewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAllPatterns = false
    @State private var showAllSuggestions = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Full Analysis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

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
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Summary
                    if let analysis = viewModel.habitsAnalysis, !analysis.summary.isEmpty {
                        summaryCard(analysis.summary)
                    }

                    // Quick stats
                    if let snapshot = viewModel.habitsSnapshot {
                        statsGrid(snapshot)
                    }

                    // Habit insights
                    if let habits = viewModel.habitsAnalysis?.habits, !habits.isEmpty {
                        habitsSection(habits)
                    }

                    // Improvement suggestions
                    if let improvements = viewModel.habitsAnalysis?.improvements, !improvements.isEmpty {
                        improvementsSection(improvements)
                    }

                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, 20)
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 500, idealHeight: 600)
        .background(Theme.primaryBackground)
    }

    private func summaryCard(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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

    private func statsGrid(_ snapshot: HabitsDataSnapshot) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]

        return VStack(alignment: .leading, spacing: 10) {
            Text("Key Metrics")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textMuted)

            LazyVGrid(columns: columns, spacing: 10) {
                StatCell(title: "Deep Work", value: "\(Int(snapshot.deepWorkRatio * 100))%", subtitle: "of active time")
                StatCell(title: "Avg Focus", value: "\(Int(snapshot.avgFocusDurationMinutes))m", subtitle: "before switching")
                StatCell(title: "Daily Active", value: String(format: "%.1fh", snapshot.avgDailyActiveHours), subtitle: "average")
                StatCell(title: "Switches/hr", value: String(format: "%.1f", snapshot.avgAppSwitchesPerHour), subtitle: "app changes")
            }
        }
    }

    private func habitsSection(_ habits: [HabitInsight]) -> some View {
        let visible = showAllPatterns ? habits : Array(habits.prefix(4))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Patterns")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                if habits.count > 4 {
                    Button(showAllPatterns ? "Show less" : "Show all") {
                        withAnimation { showAllPatterns.toggle() }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                }
            }

            ForEach(visible) { habit in
                HabitRow(habit: habit)
            }
        }
    }

    private func improvementsSection(_ improvements: [ImprovementSuggestion]) -> some View {
        let visible = showAllSuggestions ? improvements : Array(improvements.prefix(4))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Suggestions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                Spacer()
                if improvements.count > 4 {
                    Button(showAllSuggestions ? "Show less" : "Show all") {
                        withAnimation { showAllSuggestions.toggle() }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                }
            }

            ForEach(visible) { suggestion in
                SuggestionRow(suggestion: suggestion)
            }
        }
    }
}

// MARK: - Detail Sheet Components

private struct StatCell: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .tracking(0.3)

            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct HabitRow: View {
    let habit: HabitInsight

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: habit.iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(habit.category.color)
                .frame(width: 24, height: 24)
                .background(habit.category.color.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(habit.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)

                Text(habit.dataPoint)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }

            Spacer()

            if let trend = habit.trend {
                Image(systemName: trendIcon(trend))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(trendColor(trend))
            }
        }
        .padding(10)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

private struct SuggestionRow: View {
    let suggestion: ImprovementSuggestion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(suggestion.category.color)
                .frame(width: 24, height: 24)
                .background(suggestion.category.color.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Text(suggestion.description)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Text(suggestion.impact.displayName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(suggestion.impact.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(suggestion.impact.color.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(10)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
