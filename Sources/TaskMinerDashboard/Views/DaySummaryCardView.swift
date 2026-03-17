import SwiftUI
import TaskMinerShared

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
                    ProjectRow(activity: activity, expandedID: .constant(nil)) {
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
