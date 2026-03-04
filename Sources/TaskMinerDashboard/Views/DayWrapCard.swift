import SwiftUI
import TaskMinerShared

/// A celebratory end-of-day summary card with metrics and insights.
/// Shown for past days or today after 6pm.
struct DayWrapCard: View {
    let date: Date
    let focusTime: TimeInterval
    let projectCount: Int
    let meetingTime: TimeInterval
    let summaryText: String?
    let topApps: [(app: String, duration: TimeInterval, bundleId: String?)]

    @State private var isExpanded = false

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            header

            // Metrics row
            metricsRow

            // AI Summary
            if let summary = summaryText, !summary.isEmpty {
                summarySection(summary)
            }

            // Top apps chart
            if !topApps.isEmpty {
                appsChart
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isToday ? "sun.max.fill" : "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(isToday ? "Your Day So Far" : "Day Wrap")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text(dateString)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }

            Spacer()
        }
    }

    // MARK: - Metrics Row

    private var metricsRow: some View {
        HStack(spacing: 12) {
            MetricPill(
                value: formatDuration(focusTime),
                label: "focused",
                icon: "bolt.fill"
            )

            MetricPill(
                value: "\(projectCount)",
                label: projectCount == 1 ? "project" : "projects",
                icon: "folder.fill"
            )

            if meetingTime > 0 {
                MetricPill(
                    value: formatDuration(meetingTime),
                    label: "meetings",
                    icon: "person.2.fill"
                )
            }

            Spacer()
        }
    }

    // MARK: - Summary Section

    @ViewBuilder
    private func summarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isExpanded {
                // Full summary with markdown
                if let attributed = MarkdownHelper.renderMarkdown(summary) {
                    Text(attributed)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Show less")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            } else {
                // Collapsed: 2-line preview
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded = true
                        }
                    }
            }
        }
    }

    // MARK: - Apps Chart

    private var appsChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Time by App")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textMuted)

            VStack(spacing: 6) {
                ForEach(Array(topApps.prefix(4).enumerated()), id: \.offset) { _, app in
                    AppBarRow(
                        appName: app.app,
                        duration: app.duration,
                        bundleId: app.bundleId,
                        maxDuration: topApps.first?.duration ?? app.duration
                    )
                }
            }
        }
    }
}

// MARK: - Metric Pill

private struct MetricPill: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)

                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.secondaryBackground)
        )
    }
}

// MARK: - App Bar Row

private struct AppBarRow: View {
    let appName: String
    let duration: TimeInterval
    let bundleId: String?
    let maxDuration: TimeInterval

    private var barWidth: CGFloat {
        guard maxDuration > 0 else { return 0 }
        return CGFloat(duration / maxDuration)
    }

    var body: some View {
        HStack(spacing: 8) {
            // App icon
            AppIconView(bundleId: bundleId, appName: appName, size: 16)

            // Bar + label
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.secondaryBackground)

                    // Filled bar
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent.opacity(0.6))
                        .frame(width: max(geo.size.width * barWidth, 4))
                }
            }
            .frame(height: 6)

            // Duration label
            Text(formatDuration(duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 50, alignment: .trailing)
        }
        .frame(height: 20)
    }
}
