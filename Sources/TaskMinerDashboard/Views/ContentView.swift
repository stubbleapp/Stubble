import SwiftUI
import TaskMinerShared

// MARK: - Toolbar layout constants (HIG-aligned)
private enum ToolbarLayout {
    static let trailingGroupSpacing: CGFloat = 8
    static let toolbarTrailingPadding: CGFloat = 12
    static let iconButtonSize: CGFloat = 28
    static let minTouchTarget: CGFloat = 28
}

/// Tab identifiers to avoid hardcoded indices drifting out of sync.
private enum Tab: Int, CaseIterable {
    case day = 0
    case forYou = 1
    case projects = 2
    case log = 3

    var title: String {
        switch self {
        case .day: return "Day"
        case .forYou: return "For You"
        case .projects: return "Projects"
        case .log: return "Log"
        }
    }

    /// Visible tabs (excludes debug tabs unless requested).
    static func visibleTabs(includeDebug: Bool) -> [Tab] {
        includeDebug ? Tab.allCases : [.day, .forYou, .projects]
    }
}

struct ContentView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var selectedTab: Tab = .day

    /// Tracks whether the Option (⌥) key is currently held down.
    @State private var optionKeyHeld = false
    /// The debug tab (Log) is visible when Option is held OR while the user is on it.
    @State private var showDebugTabs = false
    /// NSEvent monitor reference so we can remove it on disappear.
    @State private var flagsMonitor: Any?

    private var tabItems: [String] {
        Tab.visibleTabs(includeDebug: showDebugTabs).map(\.title)
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

            // Hide date selector on For You and Projects (cross-day views)
            if selectedTab != .forYou && selectedTab != .projects {
                DaySelectorView()
                    .background(Theme.secondaryBackground)

                Rectangle()
                    .fill(Theme.separator)
                    .frame(height: 1)
            }

            ZStack(alignment: .bottom) {
                switch selectedTab {
                case .day:
                    TaskTimelineView()
                case .forYou:
                    ChatTabView()
                case .projects:
                    ProjectsView()
                case .log:
                    ActivityLogView()
                }

                // Chat overlay shared across all tabs (except Log)
                if selectedTab != .log {
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
                    selection: Binding(
                        get: { Tab.visibleTabs(includeDebug: showDebugTabs).firstIndex(of: selectedTab) ?? 0 },
                        set: { selectedTab = Tab.visibleTabs(includeDebug: showDebugTabs)[$0] }
                    )
                )
                .frame(maxWidth: 500)
                .accessibilityIdentifier("content-tab-picker")
            }

        }
        .onAppear {
            // Monitor Option key press/release to reveal the hidden Log tab
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                let isOption = event.modifierFlags.contains(.option)
                if isOption != optionKeyHeld {
                    optionKeyHeld = isOption
                    viewModel.isDebugMode = isOption
                    if isOption {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showDebugTabs = true
                        }
                    } else if selectedTab != .log {
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
            if newTab != .log && !optionKeyHeld {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showDebugTabs = false
                }
            }
            // For You is day-agnostic — always show today's recommendations
            if newTab == .forYou && !viewModel.isViewingToday {
                viewModel.selectDate(Date())
            }
            // Keep ViewModel's currentScreen in sync so chat context knows which tab is active
            viewModel.currentScreen = newTab.title
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToChatTab)) { _ in
            // Deep link from notification requested switching to For You tab
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = .forYou
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

