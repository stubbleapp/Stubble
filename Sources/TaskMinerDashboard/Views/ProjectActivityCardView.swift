import SwiftUI
import TaskMinerShared

struct ProjectActivityCardView: View {
    let activity: ProjectActivity
    @Environment(DashboardViewModel.self) var viewModel

    private var activityColor: Color {
        viewModel.resolvedColor(for: activity)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Color halo
            ActivityHaloDot(color: activityColor, size: 20)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                // Row 1: Project name + duration
                HStack(alignment: .firstTextBaseline) {
                    Text(activity.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    Text(formatDuration(activity.totalDuration * viewModel.activityDurationScale))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                }

                // Row 2: Summary
                if !activity.summary.isEmpty {
                    Text(activity.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }

                // Row 3: App icons + time range
                HStack(spacing: 8) {
                    // App icons — hover for name
                    HStack(spacing: 4) {
                        ForEach(activity.appNames.prefix(5), id: \.self) { app in
                            HoverableAppIconView(
                                appName: app,
                                bundleId: viewModel.bundleId(forAppName: app),
                                size: 18
                            )
                        }
                        if activity.appNames.count > 5 {
                            Text("+\(activity.appNames.count - 5)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 18, height: 18)
                                .background(Theme.surfaceElevated)
                                .clipShape(Circle())
                        }
                    }

                    Spacer()

                    // Time range
                    Text(formatTimeRange(start: activity.startTime, end: activity.endTime))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 10)
        }
        .padding(.trailing, 4)
    }
}
