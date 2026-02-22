import SwiftUI
import TaskMinerShared

struct ScreenshotBrowserView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var selectedScreenshot: ScreenshotRecord?

    // Multi-select state
    @State private var isSelecting = false
    @State private var selectedIds: Set<Int64> = []
    @State private var lastSelectedIndex: Int?
    @State private var showBulkDeleteConfirmation = false

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Screenshots")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                if isSelecting {
                    Text("\(selectedIds.count) selected")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)

                    Button(role: .destructive) {
                        showBulkDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .disabled(selectedIds.isEmpty)
                    .buttonStyle(.borderless)
                    .foregroundStyle(selectedIds.isEmpty ? Theme.textMuted : Theme.statusError)

                    Button("Cancel") {
                        isSelecting = false
                        selectedIds.removeAll()
                        lastSelectedIndex = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("\(viewModel.screenshots.count) screenshots")
                        .foregroundStyle(Theme.textSecondary)

                    if !viewModel.screenshots.isEmpty {
                        Button {
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding()

            if viewModel.screenshots.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.textQuaternary)
                    Text("No screenshots for this day")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(viewModel.screenshots.enumerated()), id: \.element.id) { index, screenshot in
                            ScreenshotThumbnailView(
                                screenshot: screenshot,
                                screenshotDir: viewModel.config?.screenshotDirectory ?? FileManager.default.temporaryDirectory,
                                isSelected: isSelecting && selectedIds.contains(screenshot.id ?? -1)
                            )
                            .onTapGesture {
                                handleTap(index: index, screenshot: screenshot)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $selectedScreenshot) { screenshot in
            ScreenshotDetailView(
                screenshot: screenshot,
                screenshotDir: viewModel.config?.screenshotDirectory ?? FileManager.default.temporaryDirectory,
                dbReader: viewModel.dbReader,
                tasks: viewModel.tasks
            )
        }
        .alert(
            "Delete \(selectedIds.count) Screenshot\(selectedIds.count == 1 ? "" : "s")?",
            isPresented: $showBulkDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                viewModel.deleteScreenshots(ids: selectedIds)
                selectedIds.removeAll()
                isSelecting = false
                lastSelectedIndex = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The screenshot files will be permanently removed from disk. This cannot be undone.")
        }
        .onChange(of: viewModel.selectedDate) {
            isSelecting = false
            selectedIds.removeAll()
            lastSelectedIndex = nil
        }
    }

    // MARK: - Selection Handling

    private func handleTap(index: Int, screenshot: ScreenshotRecord) {
        guard let id = screenshot.id else { return }
        let modifiers = NSEvent.modifierFlags

        if isSelecting || modifiers.contains(.command) || modifiers.contains(.shift) {
            // Enter selection mode if not already
            if !isSelecting { isSelecting = true }

            if modifiers.contains(.shift), let lastIdx = lastSelectedIndex {
                // Range select
                let range = min(lastIdx, index)...max(lastIdx, index)
                for i in range {
                    if let sid = viewModel.screenshots[i].id {
                        selectedIds.insert(sid)
                    }
                }
            } else {
                // Toggle single item
                if selectedIds.contains(id) {
                    selectedIds.remove(id)
                } else {
                    selectedIds.insert(id)
                }
            }
            lastSelectedIndex = index
        } else {
            // Normal mode: open detail
            selectedScreenshot = screenshot
        }
    }
}
