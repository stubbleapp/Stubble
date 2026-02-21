import SwiftUI
import TaskMinerShared

struct TaskCardView: View {
    let task: TaskRecord
    let isFirst: Bool
    let isLast: Bool
    @State private var isExpanded = false
    @Environment(DashboardViewModel.self) var viewModel

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline spine
            timelineSpine

            // Task content
            VStack(alignment: .leading, spacing: 4) {
                // Always visible: time + title
                HStack(spacing: 6) {
                    Text(Self.timeFmt.string(from: task.startTime))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)

                    Text(task.title)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(isExpanded ? nil : 1)
                }

                // Expanded
                if isExpanded {
                    if !task.description.isEmpty {
                        Text(task.description)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 1)
                    }

                    HStack(spacing: 4) {
                        Text(formatTimeRange(start: task.startTime, end: task.endTime))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                        Text("·")
                            .foregroundStyle(Theme.textQuaternary)
                        Text(formatDuration(task.endTime.timeIntervalSince(task.startTime)))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                    }

                    if !task.appNamesList.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(task.appNamesList, id: \.self) { app in
                                HStack(spacing: 3) {
                                    AppIconView(bundleId: viewModel.bundleId(forAppName: app), size: 14)
                                    Text(app)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.vertical, 10)

            Spacer(minLength: 4)

            // Collapsed: app icons
            if !isExpanded && !task.appNamesList.isEmpty {
                AppIconStackView(
                    appNames: task.appNamesList,
                    bundleIdResolver: { viewModel.bundleId(forAppName: $0) }
                )
                .padding(.top, 12)
            }

            // Chevron
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textQuaternary)
                .padding(.top, 14)
        }
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }

    private var timelineSpine: some View {
        GeometryReader { geo in
            let midX = geo.size.width / 2
            let dotY: CGFloat = 14
            let r: CGFloat = 4.5

            // Line above dot
            if !isFirst {
                Path { p in
                    p.move(to: CGPoint(x: midX, y: 0))
                    p.addLine(to: CGPoint(x: midX, y: dotY - r))
                }
                .stroke(Theme.spineLine, lineWidth: 1.5)
            }

            // Dot
            Circle()
                .fill(Theme.accent)
                .frame(width: r * 2, height: r * 2)
                .position(x: midX, y: dotY)

            // Line below dot
            if !isLast {
                Path { p in
                    p.move(to: CGPoint(x: midX, y: dotY + r))
                    p.addLine(to: CGPoint(x: midX, y: geo.size.height))
                }
                .stroke(Theme.spineLine, lineWidth: 1.5)
            }
        }
        .frame(width: 10)
    }

}

/// Overlapping app icon stack.
struct AppIconStackView: View {
    let appNames: [String]
    let bundleIdResolver: (String) -> String?

    var body: some View {
        HStack(spacing: -5) {
            ForEach(Array(appNames.prefix(4).enumerated()), id: \.offset) { index, name in
                AppIconView(bundleId: bundleIdResolver(name), size: 20)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Theme.primaryBackground, lineWidth: 1.5)
                    )
                    .zIndex(Double(appNames.count - index))
            }
            if appNames.count > 4 {
                Text("+\(appNames.count - 4)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 20, height: 20)
                    .background(Theme.surfaceElevated)
                    .clipShape(Circle())
            }
        }
    }
}
