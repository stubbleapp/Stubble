import SwiftUI
import TaskMinerShared

struct DaySummaryCardView: View {
    let tasks: [TaskRecord]
    let aiSummary: String?
    var daySummaryContent: String? = nil
    var projectActivities: [ProjectActivity] = []

    @State private var selectedProject: AggregatedProject?

    private var sortedProjects: [ProjectActivity] {
        projectActivities.sorted { $0.totalDuration > $1.totalDuration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !sortedProjects.isEmpty {
                ForEach(sortedProjects) { activity in
                    ProjectRow(activity: activity, expandedID: .constant(nil)) {
                        selectedProject = activity.toAggregatedProject()
                    }
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
