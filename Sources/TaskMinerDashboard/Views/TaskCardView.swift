import SwiftUI
import TaskMinerShared

/// Per-column bar info for a single task card. Each column corresponds to one of
/// the global top-3 activities and maintains a fixed horizontal position.
struct ActivityColumn: Equatable {
    let name: String
    let color: Color
    let active: Bool       // Whether this activity overlaps this task
    let continuesUp: Bool  // Same activity is also active in the previous task
    let continuesDown: Bool // Same activity is also active in the next task
}

struct TaskCardView: View {
    let task: TaskRecord
    /// Fixed-column activity bars. Always has the same count (0–3) and ordering
    /// across all task cards, so bars maintain stable horizontal positions.
    let activityColumns: [ActivityColumn]
    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var editDescription = ""
    @State private var swipeOffset: CGFloat = 0
    @State private var showDeleteConfirmation = false
    /// Debounce task for commit-on-blur to avoid race conditions with rapid focus changes.
    @State private var commitDebounceTask: Task<Void, Never>?
    @FocusState private var titleFocused: Bool
    @FocusState private var descriptionFocused: Bool
    @Environment(DashboardViewModel.self) var viewModel

    /// Single-expand: only one task can be expanded at a time.
    private var isExpanded: Bool {
        viewModel.expandedTaskId == task.id
    }

    /// How far the user must drag to reveal the delete action.
    private let deleteThreshold: CGFloat = -70
    /// How far a full swipe triggers immediate deletion.
    private let fullSwipeThreshold: CGFloat = -200

    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete background — revealed on swipe
            if swipeOffset < 0 {
                HStack(spacing: 0) {
                    Spacer()
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 60)
                            .frame(maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                    .background(Theme.statusError)
                }
            }

            // Foreground content
            cardContent
                .background(Theme.secondaryBackground)
                .offset(x: swipeOffset)
                .gesture(swipeGesture)
        }
        .clipped()
        .contextMenu {
            Button {
                startEditing()
            } label: {
                Label("Edit Task", systemImage: "pencil")
            }
        }
        .onChange(of: titleFocused) { _, focused in
            handleFocusChange(focused)
        }
        .onChange(of: descriptionFocused) { _, focused in
            handleFocusChange(focused)
        }
        .alert("Delete Task?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                guard let id = task.id else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    viewModel.deleteTask(id: id)
                }
            }
            Button("Cancel", role: .cancel) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    swipeOffset = 0
                }
            }
        } message: {
            Text("This will permanently remove \"\(task.title)\".")
        }
    }

    /// Whether any activity column is active for this task.
    private var hasActiveColumns: Bool {
        activityColumns.contains { $0.active }
    }

    // MARK: - Card content

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 0) {
            // Activity color flags — fixed columns so each activity keeps its
            // horizontal position across all task cards. Inactive columns render
            // as transparent spacers to maintain alignment.
            if !activityColumns.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(activityColumns.enumerated()), id: \.offset) { _, col in
                        if col.active {
                            ActivityBarSegment(
                                color: col.color,
                                continuesUp: col.continuesUp,
                                continuesDown: col.continuesDown
                            )
                            .frame(width: 4)
                            .help(col.name)
                        } else {
                            // Invisible spacer keeps the column position stable
                            Color.clear
                                .frame(width: 4)
                        }
                    }
                }
                .unredacted()
                .padding(.trailing, 6)
                .padding(.leading, 4)
            } else {
                // When no activity columns, add a small left inset
                Spacer()
                    .frame(width: 4)
            }

            // Task content
            VStack(alignment: .leading, spacing: 4) {
                // Always visible: time + title
                HStack(spacing: 6) {
                    Text(SharedFormatters.timeFormatter.string(from: task.startTime))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)

                    if isEditing {
                        TextField("Task title", text: $editTitle, axis: .vertical)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Theme.textPrimary)
                            .focused($titleFocused)
                            .textFieldStyle(.plain)
                    } else {
                        Text(task.title)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(isExpanded ? nil : 1)
                    }
                }

                // Expanded or editing
                if isExpanded || isEditing {
                    if isEditing {
                        TextField("Description", text: $editDescription, axis: .vertical)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .focused($descriptionFocused)
                            .textFieldStyle(.plain)
                            .lineLimit(1...8)
                            .padding(.top, 1)
                    } else if !task.description.isEmpty {
                        Text(task.description)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 1)
                    }

                    HStack(spacing: 4) {
                        Text(formatTimeRange(start: task.startTime, end: task.endTime))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                        Text("\u{00B7}")
                            .foregroundStyle(Theme.textQuaternary)
                        Text(formatDuration(task.duration))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                    }

                    if !task.appNamesList.isEmpty || !task.websitesList.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(task.appNamesList, id: \.self) { app in
                                HoverableAppIconView(
                                    appName: app,
                                    bundleId: viewModel.bundleId(forAppName: app),
                                    size: 16
                                )
                            }
                            ForEach(task.websitesList, id: \.self) { domain in
                                HoverableFaviconView(domain: domain, size: 16)
                            }
                        }
                        .padding(.top, 2)
                        .padding(.bottom, 6)
                    }

                    // Relevant links
                    if !isEditing && !task.linksList.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(Array(task.linksList.prefix(5).enumerated()), id: \.offset) { _, link in
                                LinkChipView(link: link)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.vertical, 10)

            Spacer(minLength: 4)

            // Collapsed: app icons + favicons (sorted by time spent)
            if !isExpanded && !isEditing && (!task.appNamesList.isEmpty || !task.websitesList.isEmpty) {
                AppIconStackView(
                    appNames: viewModel.sortedAppNames(for: task),
                    websites: task.websitesList,
                    bundleIdResolver: { viewModel.bundleId(forAppName: $0) }
                )
                .padding(.top, 12)
            }

            // Chevron (hide during editing)
            if !isEditing {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textQuaternary)
                    .padding(.top, 14)
            }
        }
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing else { return }
            if swipeOffset < 0 {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    swipeOffset = 0
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        viewModel.expandedTaskId = nil
                    } else {
                        // Collapse any other expanded item across the whole screen
                        viewModel.expandedTaskId = task.id
                        viewModel.expandedProjectActivityId = nil
                        viewModel.expandedActivityGroupId = nil
                    }
                }
            }
        }
    }

    // MARK: - Swipe gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isEditing else { return }
                let horizontal = value.translation.width
                // Only allow left swipe (negative)
                if horizontal < 0 {
                    // Rubber-band effect past the delete threshold
                    swipeOffset = horizontal * (horizontal < fullSwipeThreshold ? 0.3 : 1.0)
                } else if swipeOffset < 0 {
                    // Allow dragging back to reset
                    swipeOffset = min(0, swipeOffset + horizontal)
                }
            }
            .onEnded { value in
                guard !isEditing else { return }
                let horizontal = value.translation.width

                if horizontal < fullSwipeThreshold {
                    // Full swipe — trigger delete immediately
                    showDeleteConfirmation = true
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        swipeOffset = deleteThreshold
                    }
                } else if horizontal < deleteThreshold {
                    // Past threshold — snap to reveal delete button
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        swipeOffset = deleteThreshold
                    }
                } else {
                    // Not enough — snap back
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        swipeOffset = 0
                    }
                }
            }
    }

    // MARK: - Focus handling

    /// Handles focus changes with debouncing to avoid race conditions.
    /// Cancels any pending commit if focus returns to a field.
    private func handleFocusChange(_ focused: Bool) {
        if focused {
            // User focused a field — cancel any pending commit
            commitDebounceTask?.cancel()
            commitDebounceTask = nil
        } else if !titleFocused && !descriptionFocused && isEditing {
            // Both fields lost focus while editing — debounce the commit
            commitDebounceTask?.cancel()
            commitDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                // Re-check focus state after delay (user may have clicked another field)
                if !titleFocused && !descriptionFocused && isEditing {
                    commitEdit()
                }
            }
        }
    }

    // MARK: - Inline editing helpers

    private func startEditing() {
        editTitle = task.title
        editDescription = task.description
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditing = true
            viewModel.expandedTaskId = task.id
            viewModel.expandedProjectActivityId = nil
            viewModel.expandedActivityGroupId = nil
            swipeOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            titleFocused = true
        }
    }

    private func commitEdit() {
        let trimmedTitle = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, let id = task.id {
            viewModel.updateTask(id: id, title: trimmedTitle, description: editDescription)
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditing = false
        }
    }

}

/// A single vertical color bar segment that connects to adjacent cards.
/// Uses rounded caps only at the true start/end of an activity run;
/// flat edges where the activity continues to/from adjacent tasks.
struct ActivityBarSegment: View {
    let color: Color
    let continuesUp: Bool
    let continuesDown: Bool

    private let barWidth: CGFloat = 4
    private let inset: CGFloat = 4 // visual breathing room at start/end of a run

    var body: some View {
        GeometryReader { geo in
            let top: CGFloat = continuesUp ? 0 : inset
            let bottom = continuesDown ? geo.size.height : geo.size.height - inset
            let height = bottom - top

            // Determine which corners should be rounded
            let topCorners: CGFloat = continuesUp ? 0 : barWidth / 2
            let bottomCorners: CGFloat = continuesDown ? 0 : barWidth / 2

            UnevenRoundedRectangle(
                topLeadingRadius: topCorners,
                bottomLeadingRadius: bottomCorners,
                bottomTrailingRadius: bottomCorners,
                topTrailingRadius: topCorners
            )
            .fill(color)
            .frame(height: height)
            .offset(y: top)
        }
    }
}

/// Clickable link chip — opens the URL/file when clicked.
/// Uses onTapGesture + gesture blocking so taps don't propagate to the
/// parent card's expand/collapse gesture.
struct LinkChipView: View {
    let link: ExtractedLink
    @State private var isHovered = false

    private var icon: String {
        switch link.kind {
        case .url: return "link"
        case .filePath: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
            Text(link.label)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(isHovered ? Theme.accent.opacity(0.15) : Theme.accent.opacity(0.08))
        .cornerRadius(4)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(link.value)
        .highPriorityGesture(
            TapGesture().onEnded {
                if let url = link.openableURL {
                    NSWorkspace.shared.open(url)
                }
            }
        )
    }
}

/// Simple wrapping flow layout for link chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        totalHeight = y + rowHeight
        return LayoutResult(size: CGSize(width: maxWidth, height: totalHeight), positions: positions)
    }
}

/// Overlapping stack of app icons and website favicons for the collapsed task card.
struct AppIconStackView: View {
    let appNames: [String]
    var websites: [String] = []
    let bundleIdResolver: (String) -> String?

    private let maxIcons = 3

    var body: some View {
        let totalCount = appNames.count + websites.count
        let appSlice = Array(appNames.prefix(maxIcons))
        let remainingSlots = max(0, maxIcons - appSlice.count)
        let siteSlice = Array(websites.prefix(remainingSlots))
        let shownCount = appSlice.count + siteSlice.count

        HStack(spacing: -4) {
            ForEach(Array(appSlice.enumerated()), id: \.offset) { index, name in
                AppIconView(bundleId: bundleIdResolver(name), appName: name, size: 20)
                    .background(
                        Circle()
                            .fill(Theme.secondaryBackground)
                            .frame(width: 22, height: 22)
                    )
                    .zIndex(Double(totalCount - index))
            }
            ForEach(Array(siteSlice.enumerated()), id: \.offset) { index, domain in
                FaviconView(domain: domain, size: 20)
                    .background(
                        Circle()
                            .fill(Theme.secondaryBackground)
                            .frame(width: 22, height: 22)
                    )
                    .zIndex(Double(totalCount - appSlice.count - index))
            }
            if totalCount > maxIcons {
                Text("+\(totalCount - shownCount)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 20, height: 20)
                    .background(Theme.surfaceElevated)
                    .clipShape(Circle())
            }
        }
    }
}
