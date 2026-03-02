import SwiftUI
import TaskMinerShared

struct ActivityGroupView: View {
    let group: ActivityGroup
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Group header
            HStack(spacing: 10) {
                AppIconView(bundleId: group.bundleId, appName: group.appName, size: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(group.appName)
                        .font(.system(size: 13, weight: .medium))
                    if group.activities.count == 1,
                       let title = group.activities.first?.windowTitle {
                        Text(title)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    } else {
                        Text("\(group.activities.count) segments")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(formatTimeRange(start: group.startTime, end: group.endTime))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                    Text(formatDuration(group.totalDuration))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }

                if group.activities.count > 1 {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textQuaternary)
                        .frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Theme.cardBackground)
            .cornerRadius(8)
            .contentShape(Rectangle())
            .onTapGesture {
                if group.activities.count > 1 {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }

            // Expanded rows
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.activities) { activity in
                        ActivityRowView(activity: activity)
                    }
                }
                .padding(.leading, 40)
                .transition(.opacity)
            }
        }
    }
}

struct ActivityRowView: View {
    let activity: ActivityRecord

    private var extractedLinks: [ExtractedLink] {
        guard let title = activity.windowTitle else { return [] }
        return LinkExtractor.linksFromWindowTitle(title, appName: activity.appName, bundleId: activity.bundleId)
    }

    var body: some View {
        HStack {
            Circle()
                .fill(Theme.accent.opacity(0.4))
                .frame(width: 5, height: 5)
            Text(activity.windowTitle ?? "(no title)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            if let link = extractedLinks.first {
                Button {
                    if let url = link.openableURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: link.kind == .url ? "arrow.up.right.square" : "doc")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help(link.value)
            }

            Spacer()
            Text(formatDuration(activity.duration ?? 0))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
            Text(activity.timestamp, style: .time)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
    }
}
