import SwiftUI
import TaskMinerShared

/// Pause/resume control for the toolbar — circular icon button with centered icon.
struct PauseControlView: View {
    @Environment(DashboardViewModel.self) var viewModel
    /// Diameter of the circular button. Default 28.
    var iconSize: CGFloat = 28

    var body: some View {
        if viewModel.pauseState != nil {
            // Paused → simple play button to resume
            Button(action: { viewModel.resumeMonitoring() }) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: iconSize, height: iconSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: iconSize, height: iconSize)
            .modifier(NoToolbarGlassModifier())
            .accessibilityLabel("Resume monitoring")
        } else {
            // Active → menu to choose pause duration.
            // The icon is overlaid on top of the Menu so its centering
            // is completely independent of Menu's internal layout/padding.
            Menu {
                Button("15 minutes") { viewModel.pause(for: 15 * 60) }
                Button("30 minutes") { viewModel.pause(for: 30 * 60) }
                Button("1 hour") { viewModel.pause(for: 60 * 60) }
                Divider()
                Button("Until resumed") { viewModel.pause(for: nil) }
            } label: {
                Color.clear
                    .frame(width: iconSize, height: iconSize)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: iconSize, height: iconSize)
            .overlay {
                Image(systemName: "pause.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: iconSize, height: iconSize)
                    .allowsHitTesting(false)
            }
            .contentShape(Circle())
            .modifier(NoToolbarGlassModifier())
            .accessibilityLabel("Pause monitoring")
            .accessibilityHint("Opens menu to choose pause duration")
        }
    }
}

/// Disables the automatic Liquid Glass pill that macOS 26 applies to toolbar items.
private struct NoToolbarGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.identity)
        } else {
            content
        }
    }
}
