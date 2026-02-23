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

    /// Build timeline items from tasks, inserting gap indicators where the user was away.
    static func build(from tasks: [TaskRecord], gapThreshold: TimeInterval = 900) -> [TimelineItem] {
        guard !tasks.isEmpty else { return [] }

        var items: [TimelineItem] = []

        for (index, task) in tasks.enumerated() {
            // Check for gap before this task
            if index > 0 {
                let previousEnd = tasks[index - 1].endTime
                let gapDuration = task.startTime.timeIntervalSince(previousEnd)
                if gapDuration >= gapThreshold {
                    items.append(.gap(
                        id: "gap-\(index)",
                        startTime: previousEnd,
                        endTime: task.startTime,
                        duration: gapDuration
                    ))
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
}

@MainActor
extension Array where Element == TimelineItem {
    /// Activity names overlapping the nearest task before `index`.
    /// When a gap separates tasks, still returns the current task's own names
    /// so the bar extends continuously into the gap's dotted segment.
    func prevTaskActivityNames(before index: Int, viewModel: DashboardViewModel) -> Set<String> {
        let prevIndex = index - 1
        guard prevIndex >= 0 else { return [] }
        if case .gap = self[prevIndex] {
            // A gap is adjacent — report the current task's own activities
            // so the bar connects into the gap's dotted line.
            if case .task(let record, _, _) = self[index] {
                return viewModel.overlappingActivityNames(for: record)
            }
            return []
        }
        if case .task(let record, _, _) = self[prevIndex] {
            return viewModel.overlappingActivityNames(for: record)
        }
        return []
    }

    /// Activity names overlapping the nearest task after `index`.
    /// When a gap separates tasks, still returns the current task's own names
    /// so the bar extends continuously into the gap's dotted segment.
    func nextTaskActivityNames(after index: Int, viewModel: DashboardViewModel) -> Set<String> {
        let nextIndex = index + 1
        guard nextIndex < count else { return [] }
        if case .gap = self[nextIndex] {
            // A gap is adjacent — report the current task's own activities
            // so the bar connects into the gap's dotted line.
            if case .task(let record, _, _) = self[index] {
                return viewModel.overlappingActivityNames(for: record)
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
            // Date title + regenerate
            HStack {
                Text(SharedFormatters.headerDateFormatter.string(from: viewModel.selectedDate))
                    .font(.system(size: 22, weight: .bold, design: .default))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

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
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

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
                .padding(.horizontal, 16)
                .padding(.top, 10)
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
                    // Regenerating banner
                    if viewModel.isGeneratingSummary {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                            Text("Regenerating…")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Theme.accent.opacity(0.08))
                        .cornerRadius(6)
                        .padding(.top, 8)
                    }

                    // Day summary card
                    DaySummaryCardView(
                        tasks: viewModel.tasks,
                        aiSummary: viewModel.daySummaryText,
                        topActivities: viewModel.topActivityLegendItems
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                    let timelineItems = TimelineItem.build(from: viewModel.tasks)
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
                    .opacity(viewModel.isGeneratingSummary ? 0.5 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.isGeneratingSummary)
                    .padding(.horizontal, 20)

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

    var body: some View {
        GeometryReader { geo in
            Path { p in
                let midX = geo.size.width / 2
                p.move(to: CGPoint(x: midX, y: 0))
                p.addLine(to: CGPoint(x: midX, y: geo.size.height))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [0.01, 6]))
        }
    }
}
