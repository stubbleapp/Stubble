import SwiftUI
import TaskMinerShared

/// Projects tab showing aggregated project activities across configurable time periods.
struct ProjectsView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var selectedProject: AggregatedProject?

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoadingProjects && viewModel.aggregatedProjects.isEmpty {
                // Loading state
                Spacer()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading projects\u{2026}")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            } else if !viewModel.hasProjectData {
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

            // Refresh button
            Button(action: { viewModel.loadProjects() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: viewModel.isLoadingProjects)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLoadingProjects)
            .help("Refresh projects")
        }
    }

    private var timePeriodPicker: some View {
        HStack(spacing: 0) {
            ForEach(ProjectTimePeriod.allCases, id: \.self) { period in
                let isSelected = viewModel.projectsTimePeriod == period

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.setProjectsTimePeriod(period)
                    }
                } label: {
                    Text(period.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .contentShape(Capsule())
                        .background(
                            Capsule()
                                .fill(isSelected ? Theme.selectedSurface : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .modifier(TimePeriodPickerGlassModifier())
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

// MARK: - Time Period Picker Glass Modifier

private struct TimePeriodPickerGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(
                    Capsule()
                        .fill(Theme.primaryBackground.opacity(0.55))
                )
                .compositingGroup()
                .glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                )
        }
    }
}

