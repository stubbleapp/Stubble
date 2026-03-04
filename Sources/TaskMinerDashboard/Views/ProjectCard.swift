import SwiftUI
import TaskMinerShared

/// A card displaying an aggregated project with duration, days active, and apps used.
struct ProjectCard: View {
    let project: AggregatedProject
    let onTap: () -> Void

    @Environment(DashboardViewModel.self) var viewModel
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Color halo dot
                ActivityHaloDot(color: project.color, size: 16)

                // Project info
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        // Days active badge
                        Text("\(project.daysActive) day\(project.daysActive == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textMuted)

                        Circle()
                            .fill(Theme.textQuaternary)
                            .frame(width: 3, height: 3)

                        // App icons (first 4)
                        appIconsRow
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
                        color: project.color
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

    // MARK: - App Icons Row

    private var appIconsRow: some View {
        let apps = Array(project.appNames.prefix(4))
        let overflow = project.appNames.count - 4

        return HStack(spacing: 4) {
            ForEach(apps.sorted(), id: \.self) { appName in
                AppIconView(bundleId: viewModel.bundleId(forAppName: appName), appName: appName, size: 14)
                    .help(appName)
            }

            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
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

