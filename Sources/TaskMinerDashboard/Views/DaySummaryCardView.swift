import SwiftUI
import TaskMinerShared

struct DaySummaryCardView: View {
    let tasks: [TaskRecord]
    let aiSummary: String?
    var daySummaryContent: String? = nil
    var projectActivities: [ProjectActivity] = []

    @State private var isExpanded = false
    @State private var expandedActivityID: UUID?

    /// Locally-computed fallback when no AI summary is available.
    private var localSummary: String {
        guard !tasks.isEmpty else { return "" }

        let ranked = tasks
            .map { (title: $0.title, duration: $0.duration) }
            .sorted { $0.duration > $1.duration }

        if ranked.count == 1 {
            return "\(ranked[0].title) (\(formatDuration(ranked[0].duration)))"
        }

        var parts: [String] = []
        for (i, item) in ranked.prefix(3).enumerated() {
            let d = formatDuration(item.duration)
            if i == 0 {
                parts.append("Mostly \(item.title.prefix(1).lowercased())\(item.title.dropFirst()) (\(d))")
            } else {
                parts.append("\(item.title.prefix(1).lowercased())\(item.title.dropFirst()) (\(d))")
            }
        }
        if ranked.count > 3 {
            parts.append("and \(ranked.count - 3) more")
        }
        return parts.joined(separator: ", ")
    }

    /// Short summary for collapsed state.
    private var collapsedSummary: String {
        aiSummary ?? localSummary
    }

    private var sortedProjects: [ProjectActivity] {
        projectActivities.sorted { $0.totalDuration > $1.totalDuration }
    }

    /// Collapsed: top 3, Expanded: all
    private var visibleProjects: [ProjectActivity] {
        isExpanded ? sortedProjects : Array(sortedProjects.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Activity rows — top 3 when collapsed, all when expanded
            if !visibleProjects.isEmpty {
                VStack(spacing: 0) {
                    ForEach(visibleProjects) { activity in
                        ProjectRow(activity: activity, expandedID: $expandedActivityID)
                    }
                }
            }

            if isExpanded {
                // Expanded: rich summary below activities (text selectable, taps don't collapse)
                expandedSummary

                // Collapse button
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Show less")
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.top, 4)
            } else {
                // Collapsed: 2-line plain summary — tappable to expand
                if !collapsedSummary.isEmpty {
                    Text(collapsedSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded = true
                            }
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
    }

    @ViewBuilder
    private var expandedSummary: some View {
        if let richSummary = daySummaryContent {
            // Richer stubs narrative with markdown rendering
            if let attributed = MarkdownHelper.renderMarkdown(richSummary) {
                Text(attributed)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(richSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } else if !collapsedSummary.isEmpty {
            // Fall back to AI summary / local summary (full text)
            Text(collapsedSummary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
