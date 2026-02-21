import SwiftUI
import TaskMinerShared

// MARK: - Toolbar layout constants (HIG-aligned)
private enum ToolbarLayout {
    static let itemSpacing: CGFloat = 10
    static let trailingGroupSpacing: CGFloat = 12
    static let toolbarTrailingPadding: CGFloat = 12
    static let iconButtonSize: CGFloat = 28
    static let minTouchTarget: CGFloat = 28
}

struct ContentView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var selectedTab = 0
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            DaySelectorView()
                .background(Theme.secondaryBackground)

            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)

            switch selectedTab {
            case 0:
                TaskTimelineView()
            case 1:
                ActivityTimelineView()
            default:
                ScreenshotBrowserView()
            }
        }
        .background(Theme.primaryBackground)
        .toolbarBackground(Theme.secondaryBackground, for: .automatic)
        .toolbar {
            ToolbarItem(placement: .principal) {
                SegmentedPicker(
                    items: ["Tasks", "Apps", "Screens"],
                    selection: $selectedTab
                )
                .frame(maxWidth: 320)
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: ToolbarLayout.trailingGroupSpacing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .symbolVariant(.fill)
                            .frame(
                                width: ToolbarLayout.iconButtonSize,
                                height: ToolbarLayout.iconButtonSize
                            )
                            .contentShape(Rectangle())
                            .background(Theme.selectedSurface)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")

                    PauseControlView()
                }
                .padding(.trailing, ToolbarLayout.toolbarTrailingPadding)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(viewModel)
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
