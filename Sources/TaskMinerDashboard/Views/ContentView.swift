import SwiftUI
import TaskMinerShared

// MARK: - Toolbar layout constants (HIG-aligned)
private enum ToolbarLayout {
    static let trailingGroupSpacing: CGFloat = 8
    static let toolbarTrailingPadding: CGFloat = 12
    static let iconButtonSize: CGFloat = 28
    static let minTouchTarget: CGFloat = 28
}

struct ContentView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var selectedTab = 0
    @State private var showSettings = false

    /// Tracks whether the Option (⌥) key is currently held down.
    @State private var optionKeyHeld = false
    /// The Screens tab is visible when Option is held OR while the user is on it.
    @State private var showScreensTab = false
    /// NSEvent monitor reference so we can remove it on disappear.
    @State private var flagsMonitor: Any?

    private let screensTabIndex = 3

    private var tabItems: [String] {
        var items = ["Timeline", "Activities", "Tips"]
        if showScreensTab { items.append("Screens") }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.configurationError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.statusError)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(10)
                .background(Theme.statusError.opacity(0.12))
            }

            DaySelectorView()
                .background(Theme.secondaryBackground)

            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)

            switch selectedTab {
            case 0:
                ZStack(alignment: .bottom) {
                    TaskTimelineView()
                    ChatOverlayView()
                }
            case 1:
                ZStack(alignment: .bottom) {
                    ActivitiesView()
                    ChatOverlayView()
                }
            case 2:
                ZStack(alignment: .bottom) {
                    RecommendationsView()
                    ChatOverlayView()
                }
            default:
                ScreenshotBrowserView()
            }
        }
        .background(Theme.primaryBackground)
        .toolbarBackground(Theme.secondaryBackground, for: .automatic)
        .toolbar {
            ToolbarItem(placement: .principal) {
                SegmentedPicker(
                    items: tabItems,
                    selection: $selectedTab
                )
                .frame(maxWidth: 500)
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 2) {
                    Button {
                        viewModel.exportTasksCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: ToolbarLayout.iconButtonSize, height: ToolbarLayout.iconButtonSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Export Tasks")
                    .help("Export tasks as CSV")
                    .disabled(viewModel.tasks.isEmpty)
                    .opacity(viewModel.tasks.isEmpty ? 0.4 : 1)

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: ToolbarLayout.iconButtonSize, height: ToolbarLayout.iconButtonSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")

                    PauseControlView(iconSize: ToolbarLayout.iconButtonSize)
                }
                .padding(.trailing, ToolbarLayout.toolbarTrailingPadding)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(viewModel)
        }
        .onAppear {
            // Monitor Option key press/release to reveal the hidden Screens tab
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                let isOption = event.modifierFlags.contains(.option)
                if isOption != optionKeyHeld {
                    optionKeyHeld = isOption
                    if isOption {
                        // Option pressed → reveal Screens tab
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showScreensTab = true
                        }
                    } else if selectedTab != screensTabIndex {
                        // Option released while NOT on Screens → hide it
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showScreensTab = false
                        }
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = flagsMonitor {
                NSEvent.removeMonitor(monitor)
                flagsMonitor = nil
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            // User navigated away from Screens → hide the tab (unless Option still held)
            if newTab != screensTabIndex && !optionKeyHeld {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showScreensTab = false
                }
            }
        }
    }
}

/// Segmented picker — pill style, HIG-aligned spacing and touch targets.
struct SegmentedPicker: View {
    let items: [String]
    @Binding var selection: Int

    private let segmentPaddingH: CGFloat = 14
    private let segmentPaddingV: CGFloat = 6
    private let trackPadding: CGFloat = 4

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, title in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = index }
                } label: {
                    Text(title)
                        .font(.system(size: 12, weight: selection == index ? .semibold : .regular))
                        .foregroundStyle(selection == index ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, segmentPaddingH)
                        .padding(.vertical, segmentPaddingV)
                        .frame(minHeight: ToolbarLayout.minTouchTarget)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == index ? Theme.selectedSurface : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(selection == index ? [.isSelected] : [])
            }
        }
        .padding(trackPadding)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surfaceElevated)
        )
    }
}
