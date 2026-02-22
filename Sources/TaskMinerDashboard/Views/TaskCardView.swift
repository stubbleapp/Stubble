import SwiftUI
import TaskMinerShared

struct TaskCardView: View {
    let task: TaskRecord
    let isFirst: Bool
    let isLast: Bool
    @State private var isExpanded = false
    @State private var isEditing = false
    @State private var editTitle = ""
    @State private var editDescription = ""
    @State private var swipeOffset: CGFloat = 0
    @State private var showDeleteConfirmation = false
    @FocusState private var titleFocused: Bool
    @FocusState private var descriptionFocused: Bool
    @Environment(DashboardViewModel.self) var viewModel

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
                .background(Theme.primaryBackground)
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
            if !focused && !descriptionFocused && isEditing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !titleFocused && !descriptionFocused && isEditing {
                        commitEdit()
                    }
                }
            }
        }
        .onChange(of: descriptionFocused) { _, focused in
            if !focused && !titleFocused && isEditing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !titleFocused && !descriptionFocused && isEditing {
                        commitEdit()
                    }
                }
            }
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

    // MARK: - Card content

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline spine
            timelineSpine

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

            // Collapsed: app icons
            if !isExpanded && !isEditing && !task.appNamesList.isEmpty {
                AppIconStackView(
                    appNames: task.appNamesList,
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
        .overlay {
            // Tap target for expand/collapse — removed entirely during editing
            // so TextFields can receive clicks.
            if !isEditing {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if swipeOffset < 0 {
                            // Tap to dismiss swipe
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                swipeOffset = 0
                            }
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
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

    // MARK: - Inline editing helpers

    private func startEditing() {
        editTitle = task.title
        editDescription = task.description
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditing = true
            isExpanded = true
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

/// Clickable link chip — opens the URL/file when clicked.
struct LinkChipView: View {
    let link: ExtractedLink

    private var icon: String {
        switch link.kind {
        case .url: return "link"
        case .filePath: return "doc"
        }
    }

    var body: some View {
        Button {
            if let url = link.openableURL {
                NSWorkspace.shared.open(url)
            }
        } label: {
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
            .background(Theme.accent.opacity(0.08))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(link.value)
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
