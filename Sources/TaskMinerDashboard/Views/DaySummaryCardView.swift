import SwiftUI
import TaskMinerShared

/// Simple row for displaying a project activity in the day summary
private struct DaySummaryProjectRow: View {
    let activity: ProjectActivity
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Theme.accent.opacity(0.6))
                    .frame(width: 8, height: 8)

                Text(activity.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(formatDuration(activity.totalDuration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DaySummaryCardView: View {
    let tasks: [TaskRecord]
    let aiSummary: String?
    var daySummaryContent: String? = nil
    var projectActivities: [ProjectActivity] = []

    @State private var selectedProject: AggregatedProject?
    @State private var isExpanded: Bool = false

    private var sortedProjects: [ProjectActivity] {
        projectActivities.sorted { $0.totalDuration > $1.totalDuration }
    }

    /// Projects to display: top 3 when collapsed, all when expanded
    private var displayedProjects: [ProjectActivity] {
        if isExpanded || sortedProjects.count <= 3 {
            return sortedProjects
        }
        return Array(sortedProjects.prefix(3))
    }

    /// Number of hidden projects when collapsed
    private var hiddenCount: Int {
        max(0, sortedProjects.count - 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !sortedProjects.isEmpty {
                ForEach(displayedProjects) { activity in
                    DaySummaryProjectRow(activity: activity) {
                        selectedProject = activity.toAggregatedProject()
                    }
                }

                // Show more/less toggle when there are more than 3 projects
                if sortedProjects.count > 3 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Show less" : "Show \(hiddenCount) more")
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 8)
                        .padding(.leading, 32)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
        )
        .sheet(item: $selectedProject) { project in
            ProjectDetailSheet(project: project)
        }
    }
}
