import SwiftUI
import TaskMinerShared

struct ProjectActivityCardView: View {
    let activity: ProjectActivity
    @Environment(DashboardViewModel.self) var viewModel
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 0) {
            // Color bar
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.barPalette[activity.colorIndex % Theme.barPalette.count])
                .frame(width: 4)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 6) {
                // Row 1: Project name + duration badge
                HStack(alignment: .firstTextBaseline) {
                    Text(activity.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(isExpanded ? nil : 1)

                    Spacer()

                    Text(formatDuration(activity.totalDuration))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.surfaceElevated)
                        .clipShape(Capsule())
                }

                // Row 2: Summary
                if !activity.summary.isEmpty {
                    Text(activity.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(isExpanded ? nil : 2)
                }

                // Row 3: App icons + time range
                HStack(spacing: 8) {
                    // App icons
                    HStack(spacing: -4) {
                        ForEach(activity.appNames.prefix(5), id: \.self) { app in
                            AppIconView(bundleId: viewModel.bundleId(forAppName: app), size: 18)
                                .background(
                                    Circle()
                                        .fill(Theme.cardBackground)
                                        .frame(width: 20, height: 20)
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

                    // Expand chevron
                    if activity.taskTitles.count > 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textQuaternary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }

                // Expanded: constituent tasks
                if isExpanded && activity.taskTitles.count > 1 {
                    Divider()
                        .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(activity.taskTitles, id: \.self) { title in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Theme.barPalette[activity.colorIndex % Theme.barPalette.count].opacity(0.5))
                                    .frame(width: 5, height: 5)
                                Text(title)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.cardBorder.opacity(0.6), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard activity.taskTitles.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }
}
