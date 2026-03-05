import SwiftUI
import TaskMinerShared

/// A summary view shown for completed days (past days or today after wrap hour).
/// Shows: title, stats, and interactive summary with embedded project chips.
struct DayWrapCard: View {
    let focusTime: TimeInterval
    let projectCount: Int
    let meetingTime: TimeInterval
    let summaryText: String?
    let topApps: [(app: String, duration: TimeInterval, bundleId: String?)]
    var projectActivities: [ProjectActivity] = []

    @Environment(DashboardViewModel.self) var viewModel
    @State private var selectedProject: AggregatedProject?

    private var sortedProjects: [ProjectActivity] {
        projectActivities.sorted { $0.totalDuration > $1.totalDuration }
    }

    private var hasStats: Bool {
        focusTime > 0 || projectCount > 0 || meetingTime > 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            Text("Day wrapped")
                .font(Theme.headerFont(size: 22))
                .foregroundStyle(Theme.textPrimary)

            // Stats card
            if hasStats {
                statsCard
            }

            // Interactive summary with inline project chips
            if let summary = summaryText, !summary.isEmpty {
                summarySection(summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $selectedProject) { project in
            ProjectDetailSheet(project: project)
        }
    }

    // MARK: - Stats Card

    private var statsCard: some View {
        HStack(spacing: 0) {
            // Focus Time
            StatBlock(
                value: formatDuration(focusTime),
                label: "Focus",
                icon: "bolt.fill"
            )

            if projectCount > 0 {
                Divider()
                    .frame(height: 32)
                    .opacity(0.3)

                StatBlock(
                    value: "\(projectCount)",
                    label: projectCount == 1 ? "Project" : "Projects",
                    icon: "folder.fill"
                )
            }

            if meetingTime > 60 {
                Divider()
                    .frame(height: 32)
                    .opacity(0.3)

                StatBlock(
                    value: formatDuration(meetingTime),
                    label: "Meetings",
                    icon: "person.2.fill"
                )
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
        )
    }

    // MARK: - Summary Section (with inline project chips)

    @ViewBuilder
    private func summarySection(_ summary: String) -> some View {
        InteractiveSummaryText(
            summaryText: summary,
            projects: sortedProjects,
            onProjectTap: { project in
                selectedProject = project
            }
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Stat Block

private struct StatBlock: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)

                Text(value)
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
    }
}
