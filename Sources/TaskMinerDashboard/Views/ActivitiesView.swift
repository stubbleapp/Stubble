import SwiftUI
import TaskMinerShared

struct ActivitiesView: View {
    @Environment(DashboardViewModel.self) var viewModel

    var body: some View {
        VStack(spacing: 0) {
            // Date title + refresh
            HStack {
                Text(SharedFormatters.headerDateFormatter.string(from: viewModel.selectedDate))
                    .font(.system(size: 22, weight: .bold, design: .default))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                if !viewModel.tasks.isEmpty {
                    Button(action: { viewModel.generateProjectActivities(forceRegenerate: true) }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .symbolEffect(.bounce, value: viewModel.isGeneratingActivities)
                            .frame(width: 32, height: 32)
                            .background(Theme.accent.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isGeneratingActivities)
                    .help("Regenerate activities")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Error banner
            if let error = viewModel.activitiesError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.statusError)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                    Spacer()
                    Button {
                        viewModel.activitiesError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(Theme.statusError.opacity(0.06))
                .cornerRadius(8)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }

            // Content states
            if viewModel.tasks.isEmpty && !viewModel.isGeneratingSummary {
                // No tasks at all — prompt user
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.textQuaternary)

                    Text("No tasks yet")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)

                    Text("Generate a task summary first, then you can cluster tasks into project activities.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)

                    Button(action: { viewModel.generateSummary() }) {
                        Label("Generate Summary", systemImage: "sparkles")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
                }
                Spacer()
            } else if viewModel.isGeneratingActivities {
                // Loading
                Spacer()
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Clustering activities\u{2026}")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else if !viewModel.projectActivities.isEmpty {
                // Project activity cards
                ScrollView {
                    // Summary header
                    HStack {
                        Text("\(viewModel.projectActivities.count) project\(viewModel.projectActivities.count == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textMuted)

                        Spacer()

                        Text(formatDuration(viewModel.activeSeconds))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                        Text("active")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textQuaternary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.projectActivities) { activity in
                            ProjectActivityCardView(activity: activity)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Extra space so content isn't hidden behind the floating chat bar
                    Spacer()
                        .frame(height: 64)
                }
            } else {
                // Tasks exist but activities not yet generated — prompt user
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.textQuaternary)

                    Text("No activities yet")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)

                    Text("Click the refresh button to cluster your tasks into project activities.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)

                    Button(action: { viewModel.generateProjectActivities(forceRegenerate: true) }) {
                        Label("Generate Activities", systemImage: "sparkles")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
                }
                Spacer()
            }
        }
    }
}
