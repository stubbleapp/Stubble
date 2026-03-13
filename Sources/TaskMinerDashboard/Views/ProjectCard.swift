import SwiftUI
import TaskMinerShared

/// A card displaying an aggregated project with duration and sparkline.
struct ProjectCard: View {
    let project: AggregatedProject
    let onTap: () -> Void

    @Environment(DashboardViewModel.self) var viewModel
    @State private var isHovering = false

    private var summary: String {
        viewModel.projectSummary(for: project)
    }

    /// Comprehensive description built from task titles.
    private var description: String {
        // Take up to 3 unique task titles, truncated
        let uniqueTitles = Array(Set(project.taskTitles)).prefix(3)
        guard !uniqueTitles.isEmpty else { return "" }
        return uniqueTitles.map { title in
            title.count > 40 ? String(title.prefix(37)) + "..." : title
        }.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Color halo dot
                ActivityHaloDot(color: viewModel.resolvedAggregatedColor(for: project), size: 16)

                // Project info
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    // Summary line (what is this project)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }

                    // Comprehensive description (task highlights)
                    if !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 4)

                // Duration and sparkline
                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatDuration(project.totalDuration))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)

                    // Mini sparkline
                    MiniSparkline(
                        data: sparklineData,
                        color: viewModel.resolvedAggregatedColor(for: project)
                    )
                    .frame(width: 40, height: 12)
                }

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textQuaternary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovering ? Theme.surfaceElevated : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - Sparkline Data

    private var sparklineData: [Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Get last 7 days of data
        return (0..<7).reversed().map { offset -> Double in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return 0
            }
            return project.dailyDurations[date] ?? 0
        }
    }
}

// MARK: - Mini Sparkline

private struct MiniSparkline: View {
    let data: [Double]
    let color: Color

    private var maxValue: Double {
        data.max() ?? 1
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let barWidth = width / CGFloat(data.count) - 1

            HStack(spacing: 1) {
                ForEach(Array(data.enumerated()), id: \.offset) { _, value in
                    let barHeight = maxValue > 0 ? CGFloat(value / maxValue) * height : 0

                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(color.opacity(0.6))
                        .frame(width: barWidth, height: max(2, barHeight))
                        .frame(height: height, alignment: .bottom)
                }
            }
        }
    }
}

