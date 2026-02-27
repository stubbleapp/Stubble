import SwiftUI
import TaskMinerShared

/// Represents an item in the task timeline — either a task or an idle gap.
enum TimelineItem: Identifiable {
    case task(TaskRecord, isFirst: Bool, isLast: Bool)
    case gap(id: String, startTime: Date, endTime: Date, duration: TimeInterval)

    var id: String {
        switch self {
        case .task(let record, _, _):
            return "task-\(record.id ?? 0)"
        case .gap(let id, _, _, _):
            return id
        }
    }

    /// Build timeline items from tasks, inserting idle gaps between them.
    ///
    /// Gap detection uses two sources:
    /// 1. **Idle activity records** — ground truth from the daemon (screen lock, sleep, HID inactivity).
    /// 2. **Task boundary inference** — fallback when no idle records match but a significant
    ///    time hole exists between consecutive tasks (e.g. daemon was paused or crashed).
    ///
    /// Tasks are sorted by start time and overlapping boundaries are clipped so that
    /// AI-generated task merging never produces inverted inter-task windows.
    static func build(from tasks: [TaskRecord], idleActivities: [ActivityRecord] = [], minIdleDuration: TimeInterval = 120) -> [TimelineItem] {
        guard !tasks.isEmpty else { return [] }

        let idleGaps = consolidateIdlePeriods(idleActivities, minDuration: minIdleDuration)

        // Sort by start time — AI regeneration can produce out-of-order tasks
        let sorted = tasks.sorted { $0.startTime < $1.startTime }

        // Compute effective end times — clip overlapping tasks so window is never inverted.
        //    If task[i].endTime > task[i+1].startTime, clip it to task[i+1].startTime.
        //    This keeps overlap resolution local to the display layer (TaskRecord is unchanged).
        var effectiveEndTimes = sorted.map(\.endTime)
        for i in 0..<(sorted.count - 1) {
            if effectiveEndTimes[i] > sorted[i + 1].startTime {
                effectiveEndTimes[i] = sorted[i + 1].startTime
            }
        }

        var items: [TimelineItem] = []
        var usedGaps: Set<Int> = []

        for (index, task) in sorted.enumerated() {
            // Only show idle gaps BETWEEN tasks — never before the first
            // task (user hadn't started working) or after the last (user
            // is just done for the day).
            if index > 0 {
                let windowStart = effectiveEndTimes[index - 1]
                let windowEnd = task.startTime
                let interTaskGap = windowEnd.timeIntervalSince(windowStart)

                // Skip if tasks are contiguous or overlapping (already clipped above)
                if interTaskGap > 0 {
                    // Collect all idle records that overlap this inter-task window,
                    // then merge into a single gap so we never show consecutive "Away" items.
                    var mergedStart: Date?
                    var mergedEnd: Date?
                    var matchedIndices: [Int] = []

                    for (gapIndex, gap) in idleGaps.enumerated() where !usedGaps.contains(gapIndex) {
                        // Use <= for boundary-exact matches (idle starting exactly at next task)
                        if gap.end > windowStart && gap.start <= windowEnd {
                            mergedStart = min(mergedStart ?? gap.start, gap.start)
                            mergedEnd = max(mergedEnd ?? gap.end, gap.end)
                            matchedIndices.append(gapIndex)
                        }
                    }

                    if let start = mergedStart, let end = mergedEnd {
                        // Emit one combined idle gap for this window
                        let duration = end.timeIntervalSince(start)
                        items.append(.gap(
                            id: "idle-\(index)",
                            startTime: start,
                            endTime: end,
                            duration: duration
                        ))
                        for gi in matchedIndices { usedGaps.insert(gi) }
                    } else if interTaskGap >= minIdleDuration {
                        // Fallback: infer gap from task boundaries if no idle records matched
                        // and the gap is significant (>= min away threshold)
                        items.append(.gap(
                            id: "inferred-\(index)",
                            startTime: windowStart,
                            endTime: windowEnd,
                            duration: interTaskGap
                        ))
                    }
                }
            }

            let isFirst = items.isEmpty
            items.append(.task(task, isFirst: isFirst, isLast: false))
        }

        // Fix isLast on the final item
        if let lastIndex = items.indices.last {
            if case .task(let record, let isFirst, _) = items[lastIndex] {
                items[lastIndex] = .task(record, isFirst: isFirst, isLast: true)
            }
        }

        return items
    }

    /// Resolve the minimum idle duration from user settings.
    /// Must be called from the main actor (since SettingsManager is @MainActor).
    @MainActor
    static var settingsMinIdleDuration: TimeInterval {
        TimeInterval(SettingsManager.shared.minAwayMinutes * 60)
    }

    /// Consolidate idle ActivityRecords into merged time ranges.
    /// Handles unfinalized idle records (no end_time) by estimating
    /// the end from the next activity record's timestamp.
    private static func consolidateIdlePeriods(_ activities: [ActivityRecord], minDuration: TimeInterval) -> [(start: Date, end: Date)] {
        let sorted = activities.sorted { $0.timestamp < $1.timestamp }

        var idles: [(start: Date, end: Date)] = []
        for (i, record) in sorted.enumerated() {
            guard record.isIdle else { continue }

            let end: Date
            if let endTime = record.endTime {
                end = endTime
            } else if let duration = record.duration, duration > 0 {
                end = record.timestamp.addingTimeInterval(duration)
            } else {
                // Unfinalized idle record (daemon died during sleep, etc.)
                // Estimate end from the next non-idle activity's start time.
                let nextNonIdle = sorted.dropFirst(i + 1).first { !$0.isIdle }
                end = nextNonIdle?.timestamp ?? record.timestamp
            }

            let duration = end.timeIntervalSince(record.timestamp)
            guard duration >= minDuration else { continue }
            idles.append((start: record.timestamp, end: end))
        }

        guard !idles.isEmpty else { return [] }

        // Merge overlapping/adjacent idle periods
        var merged: [(start: Date, end: Date)] = [idles[0]]
        for idle in idles.dropFirst() {
            if idle.start <= merged[merged.count - 1].end {
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, idle.end)
            } else {
                merged.append(idle)
            }
        }

        return merged
    }
}

@MainActor
extension Array where Element == TimelineItem {
    /// Activity names overlapping the nearest task before `index`.
    /// When separated by a gap, returns the current task's own names so the
    /// solid bar extends flush (continuesUp = true) to meet the dotted bar.
    func prevTaskActivityNames(before index: Int, viewModel: DashboardViewModel) -> Set<String> {
        let prevIndex = index - 1
        guard prevIndex >= 0 else { return [] }
        if case .gap = self[prevIndex] {
            if case .task(let current, _, _) = self[index] {
                return viewModel.overlappingActivityNames(for: current)
            }
            return []
        }
        if case .task(let record, _, _) = self[prevIndex] {
            return viewModel.overlappingActivityNames(for: record)
        }
        return []
    }

    /// Activity names overlapping the nearest task after `index`.
    /// When separated by a gap, returns the current task's own names so the
    /// solid bar extends flush (continuesDown = true) to meet the dotted bar.
    func nextTaskActivityNames(after index: Int, viewModel: DashboardViewModel) -> Set<String> {
        let nextIndex = index + 1
        guard nextIndex < count else { return [] }
        if case .gap = self[nextIndex] {
            if case .task(let current, _, _) = self[index] {
                return viewModel.overlappingActivityNames(for: current)
            }
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
                // Empty state — no tasks at all
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.textQuaternary)

                    Text("No tasks yet")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)

                    Button(action: { viewModel.generateSummary() }) {
                        Label("Generate Summary", systemImage: "sparkles")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
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

                    // Extra space so content isn't hidden behind the floating chat bar
                    Spacer()
                        .frame(height: 64)
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
