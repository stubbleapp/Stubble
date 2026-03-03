import SwiftUI
import TaskMinerShared

// TimelineItem is defined in TaskMinerShared/Processing/TimelineBuilder.swift

extension TimelineItem {
    /// Resolve the minimum idle duration from user settings.
    /// Must be called from the main actor (since SettingsManager is @MainActor).
    @MainActor
    static var settingsMinIdleDuration: TimeInterval {
        TimeInterval(SettingsManager.shared.minAwayMinutes * 60)
    }
}

@MainActor
extension Array where Element == TimelineItem {
    /// Activity names overlapping the nearest task before `index`.
    /// Returns empty when separated by a gap, so bars get rounded tops after away periods.
    func prevTaskActivityNames(before index: Int, viewModel: DashboardViewModel) -> Set<String> {
        let prevIndex = index - 1
        guard prevIndex >= 0 else { return [] }
        // Gap before this task → bar should have rounded top (return empty)
        if case .gap = self[prevIndex] {
            return []
        }
        if case .task(let record, _, _) = self[prevIndex] {
            return viewModel.overlappingActivityNames(for: record)
        }
        return []
    }

    /// Activity names overlapping the nearest task after `index`.
    /// Returns empty when separated by a gap, so bars get rounded bottoms before away periods.
    func nextTaskActivityNames(after index: Int, viewModel: DashboardViewModel) -> Set<String> {
        let nextIndex = index + 1
        guard nextIndex < count else { return [] }
        // Gap after this task → bar should have rounded bottom (return empty)
        if case .gap = self[nextIndex] {
            return []
        }
        if case .task(let record, _, _) = self[nextIndex] {
            return viewModel.overlappingActivityNames(for: record)
        }
        return []
    }

    /// Build activity columns for a gap at `index`.
    /// An activity is shown as a dotted bar if it was active in the task
    /// immediately before the gap.
    func gapColumns(at index: Int, viewModel: DashboardViewModel) -> [ActivityColumn] {
        let top3 = viewModel.top3Activities
        guard !top3.isEmpty else { return [] }

        // Find the task before this gap
        let prevIndex = index - 1
        guard prevIndex >= 0, case .task(let record, _, _) = self[prevIndex] else { return [] }

        let prevNames = viewModel.overlappingActivityNames(for: record)

        return top3.map { activity in
            let wasActive = prevNames.contains(activity.name)
            return ActivityColumn(
                name: activity.name,
                color: activity.color,
                active: wasActive,
                continuesUp: true,
                continuesDown: true
            )
        }
    }

    /// Build fixed-column activity bars for a task at `index`.
    /// Each of the global top-3 activities gets a stable column; inactive columns
    /// become transparent spacers so bars stay aligned across cards.
    func activityColumns(at index: Int, viewModel: DashboardViewModel) -> [ActivityColumn] {
        guard case .task(let task, _, _) = self[index] else { return [] }
        let top3 = viewModel.top3Activities
        guard !top3.isEmpty else { return [] }

        let currentNames = viewModel.overlappingActivityNames(for: task)
        let prevNames = prevTaskActivityNames(before: index, viewModel: viewModel)
        let nextNames = nextTaskActivityNames(after: index, viewModel: viewModel)

        return top3.map { activity in
            let active = currentNames.contains(activity.name)
            return ActivityColumn(
                name: activity.name,
                color: activity.color,
                active: active,
                continuesUp: active && prevNames.contains(activity.name),
                continuesDown: active && nextNames.contains(activity.name)
            )
        }
    }
}

struct TaskTimelineView: View {
    @Environment(DashboardViewModel.self) var viewModel

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header — stays above scrolling content
            VStack(spacing: 0) {
                // Date title + regenerate
                HStack(alignment: .top) {
                    Text(SharedFormatters.headerDateFormatter.string(from: viewModel.selectedDate))
                        .font(Theme.headerFont(size: 24))
                        .foregroundStyle(Theme.textPrimary)

                    Spacer()

                    Button(action: { viewModel.exportTasksCSV() }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 32, height: 32)
                            .background(Theme.accent.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.tasks.isEmpty)
                    .opacity(viewModel.tasks.isEmpty ? 0.4 : 1)
                    .help("Export tasks as CSV")

                    if viewModel.isViewingToday {
                        Button(action: { viewModel.generateSummary() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .symbolEffect(.bounce, value: viewModel.isGeneratingSummary)
                                .frame(width: 32, height: 32)
                                .background(Theme.accent.opacity(0.08))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isGeneratingSummary)
                        .help("Regenerate tasks")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                // Error banner
                if let error = viewModel.summaryError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.statusError)
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3)
                        Spacer()
                        Button {
                            viewModel.summaryError = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(Theme.textMuted)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(10)
                    .background(Theme.statusError.opacity(0.06))
                    .cornerRadius(8)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                }
            }

            // Content
            if viewModel.tasks.isEmpty && !viewModel.isGeneratingSummary {
                // Empty state — no tasks yet
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "cup.and.heat.waves")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.textQuaternary)

                    Text("Your timeline is brewing")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)

                    Text("Carry on about your day — check back\nin a bit to see what you've been up to.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else if viewModel.tasks.isEmpty && viewModel.isGeneratingSummary {
                // First generation — no existing tasks to show
                Spacer()
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Analyzing…")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else {
                // Task list — keep visible during regeneration
                ScrollView {
                    // Day summary card
                    DaySummaryCardView(
                        tasks: viewModel.tasks,
                        aiSummary: viewModel.daySummaryText,
                        daySummaryContent: viewModel.daySummaryContent,
                        projectActivities: viewModel.projectActivities
                    )
                    .redacted(reason: viewModel.isGeneratingSummary ? .placeholder : [])
                    .shimmer(active: viewModel.isGeneratingSummary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                    let timelineItems = TimelineItem.build(from: viewModel.tasks, idleActivities: viewModel.activities, minIdleDuration: TimelineItem.settingsMinIdleDuration)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(timelineItems.enumerated()), id: \.element.id) { index, item in
                            switch item {
                            case .task(let task, _, _):
                                TaskCardView(
                                    task: task,
                                    activityColumns: timelineItems.activityColumns(at: index, viewModel: viewModel)
                                )
                            case .gap(_, let startTime, let endTime, let duration):
                                IdleGapView(
                                    startTime: startTime,
                                    endTime: endTime,
                                    duration: duration,
                                    gapColumns: timelineItems.gapColumns(at: index, viewModel: viewModel)
                                )
                            }
                        }
                    }
                    .redacted(reason: viewModel.isGeneratingSummary ? .placeholder : [])
                    .shimmer(active: viewModel.isGeneratingSummary)
                    .allowsHitTesting(!viewModel.isGeneratingSummary)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.isGeneratingSummary)
                    .padding(.horizontal, 24)

                    // Extra space so content isn't hidden behind the floating chat bar + suggestion pills
                    Spacer()
                        .frame(height: 100)
                }
            }
        }
    }
}

/// Visual indicator for idle/away gaps between tasks.
struct IdleGapView: View {
    let startTime: Date
    let endTime: Date
    let duration: TimeInterval
    /// Activity columns carried through the gap as dotted lines.
    var gapColumns: [ActivityColumn]

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Dotted activity bars during the gap
            if !gapColumns.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(gapColumns.enumerated()), id: \.offset) { _, col in
                        if col.active {
                            // Dotted line — continuous but visually distinct
                            DottedBarSegment(color: col.color)
                                .frame(width: 4)
                        } else {
                            Color.clear
                                .frame(width: 4)
                        }
                    }
                }
                .padding(.trailing, 6)
                .padding(.leading, 4)
            } else {
                Spacer()
                    .frame(width: 4)
            }

            // Gap content
            HStack(spacing: 4) {
                Text("Away")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textQuaternary)
                Text(formatDuration(duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textQuaternary)
            }

            Spacer()
        }
        .padding(.trailing, 4)
        .frame(height: 32)
    }
}

/// A dotted vertical bar for activity columns during away gaps.
private struct DottedBarSegment: View {
    let color: Color

    private let dotStrokeWidth: CGFloat = 4
    private let verticalInset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Path { p in
                let midX = geo.size.width / 2
                p.move(to: CGPoint(x: midX, y: verticalInset))
                p.addLine(to: CGPoint(x: midX, y: geo.size.height - verticalInset))
            }
            .stroke(color, style: StrokeStyle(lineWidth: dotStrokeWidth, lineCap: .round, dash: [0.01, 6]))
        }
    }
}
