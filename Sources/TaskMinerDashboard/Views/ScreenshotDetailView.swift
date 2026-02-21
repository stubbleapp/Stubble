import SwiftUI
import TaskMinerShared

struct ScreenshotDetailView: View {
    let screenshot: ScreenshotRecord
    let screenshotDir: URL
    let dbReader: DatabaseReader?
    let tasks: [TaskRecord]
    @Environment(DashboardViewModel.self) var viewModel
    @Environment(\.dismiss) var dismiss
    @State private var linkedActivity: ActivityRecord?
    @State private var showDeleteConfirmation = false

    /// The AI-generated task whose time range contains this screenshot's timestamp.
    private var matchingTask: TaskRecord? {
        tasks.first { task in
            screenshot.timestamp >= task.startTime && screenshot.timestamp <= task.endTime
        }
    }

    private var fullPath: URL {
        screenshotDir.appendingPathComponent(screenshot.filePath)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(screenshot.timestamp, format: .dateTime)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()

                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.statusError)
                }
                .buttonStyle(.borderless)
                .help("Delete this screenshot")

                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()

            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)

            // Main content: image + metadata sidebar
            HStack(spacing: 0) {
                // Screenshot image
                Group {
                    if let image = NSImage(contentsOf: fullPath) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding()
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundStyle(Theme.statusError)
                            Text("Screenshot file not available")
                                .foregroundStyle(Theme.textSecondary)
                            if screenshot.ocrText != nil {
                                Text("OCR text preserved in database")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                Rectangle()
                    .fill(Theme.separator)
                    .frame(width: 1)

                // Metadata sidebar
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        metadataSection("Capture Info", icon: "camera") {
                            metadataRow("Trigger", value: triggerLabel)
                            metadataRow("Time", value: screenshot.timestamp.formatted(date: .omitted, time: .standard))
                            if let size = screenshot.fileSize {
                                metadataRow("File Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            }
                            if !screenshot.filePath.isEmpty {
                                metadataRow("Path", value: screenshot.filePath, monospaced: true)
                            }
                        }

                        metadataSection("Processing", icon: "cpu") {
                            HStack(spacing: 6) {
                                statusBadge(
                                    label: "OCR",
                                    active: screenshot.ocrText != nil
                                )
                                statusBadge(
                                    label: "AI Task",
                                    active: matchingTask != nil
                                )
                            }
                            if screenshot.ocrText == nil && screenshot.filePath.isEmpty {
                                Text("No data extracted")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }

                        if let activity = linkedActivity {
                            metadataSection("Active Window", icon: "macwindow") {
                                metadataRow("App", value: activity.appName)
                                if let title = activity.windowTitle, !title.isEmpty {
                                    metadataRow("Window", value: title)
                                }
                                if let bundleId = activity.bundleId {
                                    metadataRow("Bundle ID", value: bundleId, monospaced: true)
                                }
                                if activity.isIdle {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Theme.statusPaused)
                                            .frame(width: 6, height: 6)
                                        Text("Idle")
                                            .font(.caption)
                                            .foregroundStyle(Theme.statusPaused)
                                    }
                                }
                            }
                        }

                        if let task = matchingTask {
                            metadataSection("AI-Inferred Task", icon: "sparkles") {
                                Text(task.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                                if !task.description.isEmpty {
                                    Text(task.description)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                HStack(spacing: 12) {
                                    metadataRow(
                                        "Time Range",
                                        value: "\(task.startTime.formatted(date: .omitted, time: .shortened)) – \(task.endTime.formatted(date: .omitted, time: .shortened))"
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Confidence")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.textMuted)
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(confidenceColor(task.confidence))
                                                .frame(width: 6, height: 6)
                                            Text("\(Int(task.confidence * 100))%")
                                                .font(.caption)
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                }
                                if !task.appNamesList.isEmpty {
                                    metadataRow("Apps", value: task.appNamesList.joined(separator: ", "))
                                }
                            }
                        }

                        if let ocrText = screenshot.ocrText, !ocrText.isEmpty {
                            metadataSection("OCR Text", icon: "doc.text.magnifyingglass") {
                                Text(ocrText)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Theme.primaryBackground)
                                    .cornerRadius(6)
                            }
                        }
                    }
                    .padding()
                }
                .frame(width: 280)
                .background(Theme.secondaryBackground)
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .onAppear {
            if let activityId = screenshot.activityId {
                linkedActivity = dbReader?.activity(byId: activityId)
            }
        }
        .alert("Delete Screenshot?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let id = screenshot.id {
                    viewModel.deleteScreenshots(ids: [id])
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The screenshot file will be permanently removed from disk. This cannot be undone.")
        }
    }

    // MARK: - Helpers

    private func confidenceColor(_ value: Double) -> Color {
        if value >= 0.7 { return Theme.confidenceHigh }
        if value >= 0.4 { return Theme.confidenceMedium }
        return Theme.confidenceLow
    }

    private var triggerLabel: String {
        switch screenshot.trigger {
        case .appSwitch: return "App Switch"
        case .titleChange: return "Title Change"
        case .periodic: return "Periodic"
        case .manual: return "Manual"
        }
    }

    @ViewBuilder
    private func metadataSection(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            content()
        }
    }

    @ViewBuilder
    private func metadataRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func statusBadge(label: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Theme.statusActive : Theme.textQuaternary)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(active ? Theme.textSecondary : Theme.textMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((active ? Theme.statusActive : Theme.textQuaternary).opacity(0.1))
        .cornerRadius(4)
    }
}
