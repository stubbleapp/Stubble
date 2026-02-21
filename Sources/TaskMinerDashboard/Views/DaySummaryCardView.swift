import SwiftUI
import TaskMinerShared

/// Compact summary card at the top of the tasks view showing what the user did that day.
struct DaySummaryCardView: View {
    let tasks: [TaskRecord]
    let activeSeconds: Double

    @Environment(DashboardViewModel.self) var viewModel

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - Computed stats

    private var timeRange: String {
        guard let first = tasks.first, let last = tasks.last else { return "" }
        return "\(Self.timeFmt.string(from: first.startTime)) – \(Self.timeFmt.string(from: last.endTime))"
    }

    private var uniqueApps: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for task in tasks {
            for app in task.appNamesList {
                if seen.insert(app).inserted {
                    ordered.append(app)
                }
            }
        }
        return ordered
    }

    /// Build a short natural-language summary from task titles.
    private var summaryText: String {
        guard !tasks.isEmpty else { return "" }

        let titles = tasks.map { $0.title }

        if titles.count == 1 {
            return titles[0]
        }

        if titles.count == 2 {
            return "\(titles[0]) and \(titles[1].lowercased())"
        }

        // 3+ tasks: show first two + "and N more"
        let remaining = titles.count - 2
        return "\(titles[0]), \(titles[1].lowercased()), and \(remaining) more \(remaining == 1 ? "task" : "tasks")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Summary text
            Text(summaryText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Stats row
            HStack(spacing: 12) {
                // Time range
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textMuted)
                    Text(timeRange)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                }

                // Task count
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textMuted)
                    Text("\(tasks.count) \(tasks.count == 1 ? "task" : "tasks")")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }

                // Active time
                if activeSeconds > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textMuted)
                        Text(formatDuration(activeSeconds))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                    }
                }

                Spacer()

                // App icons
                if !uniqueApps.isEmpty {
                    HStack(spacing: -4) {
                        ForEach(Array(uniqueApps.prefix(6).enumerated()), id: \.offset) { index, app in
                            AppIconView(bundleId: viewModel.bundleId(forAppName: app), size: 16)
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Theme.cardBackground, lineWidth: 1)
                                )
                                .zIndex(Double(uniqueApps.count - index))
                        }
                        if uniqueApps.count > 6 {
                            Text("+\(uniqueApps.count - 6)")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 16, height: 16)
                                .background(Theme.surfaceElevated)
                                .clipShape(Circle())
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.cardBorder, lineWidth: 0.5)
        )
    }
}
