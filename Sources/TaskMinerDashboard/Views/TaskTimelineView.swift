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

struct TaskTimelineView: View {
    @Environment(DashboardViewModel.self) var viewModel

    var body: some View {
        VStack(spacing: 0) {
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

                    if viewModel.hasGeminiKey {
                        Button(action: { viewModel.generateSummary() }) {
                            Label("Generate Summary", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 4)
                    } else {
                        Text("Set GEMINI_API_KEY to enable")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
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
                        activeSeconds: viewModel.activeSeconds
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                    let timelineItems = TimelineItem.build(from: viewModel.tasks)
                    LazyVStack(spacing: 0) {
                        ForEach(timelineItems) { item in
                            switch item {
                            case .task(let task, let isFirst, let isLast):
                                TaskCardView(
                                    task: task,
                                    isFirst: isFirst,
                                    isLast: isLast
                                )
                            case .gap(_, let startTime, let endTime, let duration):
                                IdleGapView(
                                    startTime: startTime,
                                    endTime: endTime,
                                    duration: duration
                                )
                            }
                        }
                    }
                    .opacity(viewModel.isGeneratingSummary ? 0.5 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.isGeneratingSummary)
                    .padding(.horizontal, 20)

                    // Bottom refresh button
                    if viewModel.hasGeminiKey {
                        Button(action: { viewModel.generateSummary() }) {
                            HStack(spacing: 6) {
                                if viewModel.isGeneratingSummary {
                                    ProgressView()
                                        .scaleEffect(0.5)
                                        .frame(width: 14, height: 14)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                Text("Regenerate")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 20)
                            .background(Theme.accent.opacity(0.08))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isGeneratingSummary)
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                    }
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

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Timeline spine with dashed line
            gapSpine

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

    private var gapSpine: some View {
        GeometryReader { geo in
            let midX = geo.size.width / 2
            let midY = geo.size.height / 2
            let dotR: CGFloat = 2.5

            // Dashed line above
            Path { p in
                p.move(to: CGPoint(x: midX, y: 0))
                p.addLine(to: CGPoint(x: midX, y: midY - dotR - 2))
            }
            .stroke(Theme.spineLine, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

            // Small diamond/dot
            Circle()
                .fill(Theme.gapDot)
                .frame(width: dotR * 2, height: dotR * 2)
                .position(x: midX, y: midY)

            // Dashed line below
            Path { p in
                p.move(to: CGPoint(x: midX, y: midY + dotR + 2))
                p.addLine(to: CGPoint(x: midX, y: geo.size.height))
            }
            .stroke(Theme.spineLine, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }
        .frame(width: 10)
    }
}
