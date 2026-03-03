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

    /// Tracks whether the Option (⌥) key is currently held down.
    @State private var optionKeyHeld = false
    /// The debug tab (Log) is visible when Option is held OR while the user is on it.
    @State private var showDebugTabs = false
    /// NSEvent monitor reference so we can remove it on disappear.
    @State private var flagsMonitor: Any?

    private let chatTabIndex = 1
    private let habitsTabIndex = 2
    private let logTabIndex = 3

    private var tabItems: [String] {
        var items = ["Day", "Chat", "Habits"]
        if showDebugTabs {
            items.append("Log")
        }
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

            // Hide date selector on Chat (day-agnostic) and Habits (cross-day analysis)
            if selectedTab != chatTabIndex && selectedTab != habitsTabIndex {
                DaySelectorView()
                    .background(Theme.secondaryBackground)

                Rectangle()
                    .fill(Theme.separator)
                    .frame(height: 1)
            }

            ZStack(alignment: .bottom) {
                switch selectedTab {
                case 0:
                    TaskTimelineView()
                case 1:
                    ChatTabView()
                case 2:
                    HabitsView()
                default:
                    ActivityLogView()
                }

                // Chat overlay shared across all tabs (except Log)
                if selectedTab < logTabIndex {
                    ChatOverlayView()
                }
            }
        }
        .background(Theme.secondaryBackground)
        .toolbarBackground(Theme.secondaryBackground, for: .automatic)
        .toolbar {
            ToolbarItem(placement: .principal) {
                SegmentedPicker(
                    items: tabItems,
                    selection: $selectedTab
                )
                .frame(maxWidth: 500)
                .accessibilityIdentifier("content-tab-picker")
            }

            ToolbarItem(placement: .primaryAction) {
                PauseControlView()
                    .accessibilityIdentifier("toolbar-pause-control")
            }
        }
        .onAppear {
            // Monitor Option key press/release to reveal the hidden Log tab
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                let isOption = event.modifierFlags.contains(.option)
                if isOption != optionKeyHeld {
                    optionKeyHeld = isOption
                    if isOption {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showDebugTabs = true
                        }
                    } else if selectedTab != logTabIndex {
                        // Option released while NOT on the debug tab → hide it
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showDebugTabs = false
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
            // User navigated away from the debug tab → hide it (unless Option still held)
            if newTab != logTabIndex && !optionKeyHeld {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showDebugTabs = false
                }
            }
            // Chat is day-agnostic — always show today's recommendations
            if newTab == chatTabIndex && !viewModel.isViewingToday {
                viewModel.selectDate(Date())
            }
            // Keep ViewModel's currentScreen in sync so chat context knows which tab is active
            let screenNames = ["Day", "Chat", "Habits", "Log"]
            viewModel.currentScreen = newTab < screenNames.count ? screenNames[newTab] : "Chat"
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToChatTab)) { _ in
            // Deep link from notification requested switching to Chat tab
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = chatTabIndex
            }
        }
    }
}

/// Segmented picker — capsule pill with liquid glass, HIG-aligned spacing and touch targets.
struct SegmentedPicker: View {
    let items: [String]
    @Binding var selection: Int

    private let segmentPaddingH: CGFloat = 14
    private let segmentPaddingV: CGFloat = 6
    private let trackPadding: CGFloat = 4

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, title in
                let isSelected = selection == index

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = index }
                } label: {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                        .padding(.horizontal, segmentPaddingH)
                        .padding(.vertical, segmentPaddingV)
                        .frame(minHeight: ToolbarLayout.minTouchTarget)
                        .contentShape(Capsule())
                        .background(
                            Capsule()
                                .fill(isSelected ? Theme.selectedSurface : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(trackPadding)
        .modifier(SegmentedPickerGlassModifier())
    }
}

/// Liquid glass capsule for the segmented picker track.
private struct SegmentedPickerGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(
                    Capsule()
                        .fill(Theme.primaryBackground.opacity(0.55))
                )
                .compositingGroup()
                .glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                )
        }
    }
}

