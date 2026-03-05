import SwiftUI
import TaskMinerShared

/// A summary view shown for completed days (past days or today after wrap hour).
/// Shows: title, stats, AI summary, and all projects worked on.
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

            // Summary section
            if let summary = summaryText, !summary.isEmpty {
                summarySection(summary)
            }

            // Projects section
            if !sortedProjects.isEmpty {
                projectsSection
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

    // MARK: - Summary Section

    @ViewBuilder
    private func summarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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

    // MARK: - Projects Section

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack {
                Text("Projects")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Spacer()
            }

            // Project rows in a card
            VStack(spacing: 0) {
                ForEach(Array(sortedProjects.enumerated()), id: \.element.id) { index, activity in
                    ProjectWrapRow(
                        activity: activity,
                        color: viewModel.resolvedColor(for: activity),
                        scale: viewModel.activityDurationScale
                    ) {
                        selectedProject = activity.toAggregatedProject()
                    }

                    if index < sortedProjects.count - 1 {
                        Divider()
                            .padding(.leading, 32)
                            .opacity(0.5)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
            )
        }
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

// MARK: - Project Wrap Row

private struct ProjectWrapRow: View {
    let activity: ProjectActivity
    let color: Color
    let scale: Double
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Color indicator
                ActivityHaloDot(color: color, size: 14)

                // Project name
                Text(activity.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                // Duration
                Text(formatDuration(activity.totalDuration * scale))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textQuaternary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Theme.surfaceElevated : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}
