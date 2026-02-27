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
    @State private var selectedTab = 1

    /// Tracks whether the Option (⌥) key is currently held down.
    @State private var optionKeyHeld = false
    /// The debug tabs (Me, Screens) are visible when Option is held OR while the user is on one.
    @State private var showDebugTabs = false
    /// NSEvent monitor reference so we can remove it on disappear.
    @State private var flagsMonitor: Any?

    private let stubsTabIndex = 1
    private let habitsTabIndex = 2
    private let meTabIndex = 3
    private let screensTabIndex = 4

    private var tabItems: [String] {
        var items = ["Day", "Stubs", "Habits"]
        if showDebugTabs {
            items.append("Me")
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

            // Hide date selector on Stubs (day-agnostic) and Habits (cross-day analysis)
            if selectedTab != stubsTabIndex && selectedTab != habitsTabIndex {
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
                    RecommendationsView()
                case 2:
                    HabitsView()
                case 3:
                    MeView()
                default:
                    ActivityLogView()
                }

                // Single chat overlay shared across all tabs (except Log)
                if selectedTab < 4 {
                    ChatOverlayView()
                }
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
                .accessibilityIdentifier("content-tab-picker")
            }

            ToolbarItem(placement: .primaryAction) {
                PauseControlView(iconSize: ToolbarLayout.iconButtonSize)
                    .padding(.trailing, ToolbarLayout.toolbarTrailingPadding)
            }
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
                            showDebugTabs = true
                        }
                    } else if selectedTab != meTabIndex && selectedTab != screensTabIndex {
                        // Option released while NOT on a debug tab → hide them
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
            // User navigated away from debug tabs → hide them (unless Option still held)
            if newTab != meTabIndex && newTab != screensTabIndex && !optionKeyHeld {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showDebugTabs = false
                }
            }
            // Stubs is day-agnostic — always show today's recommendations
            if newTab == stubsTabIndex && !viewModel.isViewingToday {
                viewModel.selectDate(Date())
            }
            // Keep ViewModel's currentScreen in sync so chat context knows which tab is active
            let screenNames = ["Day", "Stubs", "Habits", "Me", "Log"]
            viewModel.currentScreen = newTab < screenNames.count ? screenNames[newTab] : "Stubs"
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
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
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
