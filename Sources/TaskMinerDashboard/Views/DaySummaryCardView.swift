import SwiftUI
import TaskMinerShared

struct DaySummaryCardView: View {
    let tasks: [TaskRecord]
    let aiSummary: String?
    let topActivities: [ActivityLegendItem]

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

    private var displaySummary: String {
        aiSummary ?? localSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(displaySummary)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            if !topActivities.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(topActivities.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(item.color)
                                .frame(width: 4, height: 14)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(formatDuration(item.duration))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.cardBorder.opacity(0.6), lineWidth: 0.5)
        )
    }
}

/// Data for the activity legend in the day summary card.
struct ActivityLegendItem {
    let name: String
    let color: Color
    let duration: TimeInterval
}
