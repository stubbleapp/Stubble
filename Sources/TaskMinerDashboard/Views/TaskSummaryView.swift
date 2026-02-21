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
    @State private var showDeleteConfirmation = false
    @FocusState private var titleFocused: Bool
    @FocusState private var descriptionFocused: Bool
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

                    // Delete action
                    HStack(spacing: 8) {
                        Spacer()

                        Button {
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.statusError.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                        .help("Delete task")
                    }
                    .padding(.top, 4)
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
        .background {
            // Invisible tap target for expand/collapse — only active when NOT editing.
            // Using .background instead of .onTapGesture so it doesn't steal
            // focus from TextFields during editing.
            if !isEditing {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            startEditing()
                        }
                    )
            }
        }
        .contextMenu {
            Button {
                startEditing()
            } label: {
                Label("Edit Task", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete Task", systemImage: "trash")
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
                viewModel.deleteTask(id: id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove \"\(task.title)\". This cannot be undone.")
        }
    }

    // MARK: - Inline editing helpers

    private func startEditing() {
        editTitle = task.title
        editDescription = task.description
        withAnimation(.easeInOut(duration: 0.2)) {
            isEditing = true
            isExpanded = true
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
