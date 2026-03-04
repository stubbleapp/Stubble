import SwiftUI
import TaskMinerShared

/// A summary view shown for completed days (past days or today after wrap hour).
/// Shows: title, stats, AI summary, and all projects worked on.
/// No card styling - renders directly on the view background.
struct DayWrapCard: View {
    let focusTime: TimeInterval
    let projectCount: Int
    let meetingTime: TimeInterval
    let summaryText: String?
    let topApps: [(app: String, duration: TimeInterval, bundleId: String?)]
    var projectActivities: [ProjectActivity] = []

    @State private var selectedProject: AggregatedProject?

    private var sortedProjects: [ProjectActivity] {
        projectActivities.sorted { $0.totalDuration > $1.totalDuration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header: "Day wrapped" in same font as date
            Text("Day wrapped")
                .font(Theme.headerFont(size: 20))
                .foregroundStyle(Theme.textPrimary)

            // Prominent stats section
            statsSection

            // Summary BEFORE projects
            if let summary = summaryText, !summary.isEmpty {
                summarySection(summary)
            }

            // ALL projects (no limit)
            if !sortedProjects.isEmpty {
                VStack(spacing: 0) {
                    ForEach(sortedProjects) { activity in
                        ProjectRow(activity: activity, expandedID: .constant(nil)) {
                            selectedProject = activity.toAggregatedProject()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $selectedProject) { project in
            ProjectDetailSheet(project: project)
        }
    }

    // MARK: - Stats Section (more prominent)

    private var statsSection: some View {
        HStack(spacing: 32) {
            StatItem(
                icon: "bolt.fill",
                label: "Focus Time",
                value: formatDuration(focusTime)
            )

            if projectCount > 0 {
                StatItem(
                    icon: "folder.fill",
                    label: "Projects",
                    value: "\(projectCount)"
                )
            }

            if meetingTime > 60 {
                StatItem(
                    icon: "person.2.fill",
                    label: "Meetings",
                    value: formatDuration(meetingTime)
                )
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Summary Section

    @ViewBuilder
    private func summarySection(_ summary: String) -> some View {
        if let attributed = MarkdownHelper.renderMarkdown(summary) {
            Text(attributed)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            Text(summary)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Stat Item (larger, more prominent)

private struct StatItem: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)

                Text(value)
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
    }
}
