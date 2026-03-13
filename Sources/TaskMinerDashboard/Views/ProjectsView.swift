import SwiftUI
import TaskMinerShared

/// Projects tab showing aggregated project activities across configurable time periods.
struct ProjectsView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var selectedProject: AggregatedProject?

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.hasProjectData && !viewModel.isLoadingProjects {
                // Empty state
                Spacer()
                emptyState
                Spacer()
            } else {
                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header with time picker
                        headerSection
                            .padding(.horizontal, 24)
                            .padding(.top, 20)
                            .padding(.bottom, 16)

                        // Error banner
                        if let error = viewModel.projectsError {
                            errorBanner(error)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                        }

                        // Total time header (right-aligned above project durations)
                        totalTimeHeader
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)

                        // Project list
                        LazyVStack(spacing: 4) {
                            ForEach(viewModel.aggregatedProjects) { project in
                                ProjectCard(project: project) {
                                    selectedProject = project
                                }
                            }
                        }
                        .padding(.horizontal, 16)

                        Spacer().frame(height: 100)
                    }
                }
            }
        }
        .onAppear {
            if viewModel.aggregatedProjects.isEmpty {
                viewModel.loadProjects()
            }
        }
        .sheet(item: $selectedProject) { project in
            ProjectDetailSheet(project: project)
                .environment(viewModel)
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Projects")
                    .font(Theme.headerFont(size: 20))
                    .foregroundStyle(Theme.textPrimary)

                Text("\(viewModel.aggregatedProjects.count) project\(viewModel.aggregatedProjects.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }

            Spacer()

            // Time period picker
            timePeriodPicker
        }
    }

    private var timePeriodPicker: some View {
        HStack(spacing: 16) {
            ForEach(ProjectTimePeriod.allCases, id: \.self) { period in
                let isSelected = viewModel.projectsTimePeriod == period

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.setProjectsTimePeriod(period)
                    }
                } label: {
                    Text(period.displayName)
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Total Time Header

    private var totalTimeHeader: some View {
        HStack {
            Spacer()
            Text("Total: \(formatDuration(viewModel.totalProjectsTime))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textMuted)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textMuted.opacity(0.5))

            Text("No project data for this period.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Text("Projects appear here as you work.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textQuaternary)
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.projectsError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.statusError.opacity(0.2), lineWidth: 0.5)
        )
    }
}


