import SwiftUI
import TaskMinerShared

/// Renders summary text with inline tappable project chips, supporting paragraphs
struct InteractiveSummaryText: View {
    let summaryText: String
    let projects: [ProjectActivity]
    let onProjectTap: (AggregatedProject) -> Void

    @Environment(DashboardViewModel.self) var viewModel

    /// Split text into paragraphs, then parse each for segments
    private var paragraphs: [[SummarySegment]] {
        // Use all known project names for matching, not just this day's projects
        let allProjectNames = viewModel.allKnownProjects.map(\.name)
        let paras = summaryText.components(separatedBy: "\n\n")
        return paras.map { para in
            InteractiveSummaryParser.parse(para, projectNames: allProjectNames)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, segments in
                InlineFlowLayout(horizontalSpacing: 0, verticalSpacing: 8) {
                    ForEach(segments) { segment in
                        segmentViews(for: segment)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func segmentViews(for segment: SummarySegment) -> some View {
        switch segment {
        case .text(let str):
            // Render text as individual words for proper wrapping
            ForEach(Array(splitIntoWords(str).enumerated()), id: \.offset) { _, word in
                if let attributed = MarkdownHelper.renderMarkdown(word.text) {
                    Text(attributed)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    Text(word.text)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                }
            }

        case .project(let name):
            if let project = findProject(name) {
                ProjectChip(
                    name: project.name,
                    color: viewModel.resolvedColor(for: project)
                ) {
                    onProjectTap(project.toAggregatedProject())
                }
            } else {
                // Fallback: render as bold text
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private func findProject(_ name: String) -> ProjectActivity? {
        // First check this day's projects
        if let found = projects.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return found
        }
        // Then check all known projects from the viewModel (lazy-loaded)
        if let found = viewModel.allKnownProjects.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return found
        }
        return nil
    }

    /// Split text into word tokens, preserving trailing spaces
    private func splitIntoWords(_ text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        var current = ""
        var inWord = false

        for char in text {
            if char == " " {
                if inWord {
                    // End of word, include the space with the word
                    current.append(char)
                    tokens.append(WordToken(text: current))
                    current = ""
                    inWord = false
                } else {
                    // Multiple spaces or leading space
                    current.append(char)
                }
            } else if char == "\n" {
                // Single newline within paragraph - treat as space
                if !current.isEmpty {
                    tokens.append(WordToken(text: current + " "))
                    current = ""
                }
                inWord = false
            } else {
                if !inWord && !current.isEmpty {
                    // Had spaces before this word, add them as a token
                    tokens.append(WordToken(text: current))
                    current = ""
                }
                current.append(char)
                inWord = true
            }
        }

        if !current.isEmpty {
            tokens.append(WordToken(text: current))
        }

        return tokens
    }
}

/// A word token for layout
private struct WordToken: Identifiable {
    let text: String
    var id: String { text + String(text.hashValue) }
}

// MARK: - Project Chip

/// Inline tappable chip showing project color and name
/// Designed to sit inline with text at the same visual weight
struct ProjectChip: View {
    let name: String
    let color: Color
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)

                Text(name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isHovered ? color.opacity(0.18) : color.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .strokeBorder(color.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Inline Flow Layout

/// Layout that wraps items inline like text, with vertical centering within each row
struct InlineFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 0, verticalSpacing: CGFloat = 4) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)

        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { continue }
            let position = result.positions[index]
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct LayoutResult {
        let size: CGSize
        let positions: [CGPoint]
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity

        // First pass: compute rows
        var rows: [[Int]] = [[]]
        var rowWidths: [CGFloat] = [0]
        var rowHeights: [CGFloat] = [0]
        var x: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)

            // Check if we need to wrap to next line
            if x + size.width > maxWidth && x > 0 {
                rows.append([])
                rowWidths.append(0)
                rowHeights.append(0)
                x = 0
            }

            rows[rows.count - 1].append(index)
            rowWidths[rows.count - 1] = x + size.width
            rowHeights[rows.count - 1] = max(rowHeights[rows.count - 1], size.height)
            x += size.width + horizontalSpacing
        }

        // Second pass: compute positions with vertical centering
        var positions: [CGPoint] = Array(repeating: .zero, count: subviews.count)
        var y: CGFloat = 0

        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = rowHeights[rowIndex]
            var x: CGFloat = 0

            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                // Center vertically within the row
                let yOffset = (rowHeight - size.height) / 2
                positions[index] = CGPoint(x: x, y: y + yOffset)
                x += size.width + horizontalSpacing
            }

            y += rowHeight + verticalSpacing
        }

        let totalHeight = y - verticalSpacing // Remove last spacing
        let maxRowWidth = rowWidths.max() ?? 0
        return LayoutResult(
            size: CGSize(width: min(maxRowWidth, maxWidth), height: max(0, totalHeight)),
            positions: positions
        )
    }
}
