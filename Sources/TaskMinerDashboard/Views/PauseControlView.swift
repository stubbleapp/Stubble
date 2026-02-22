import SwiftUI
import TaskMinerShared

private let pauseLabelPaddingH: CGFloat = 12
private let pauseLabelPaddingV: CGFloat = 5

/// Pause/resume control for the toolbar — matches icon button size when compact, capsule when resumed.
struct PauseControlView: View {
    @Environment(DashboardViewModel.self) var viewModel
    /// When set, render as a circular icon button (same size as Export/Settings). Default 28.
    var iconSize: CGFloat = 28

    var body: some View {
        if viewModel.pauseState != nil {
            Button(action: { viewModel.resumeMonitoring() }) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: iconSize, height: iconSize)
                    .contentShape(Rectangle())
                    .background(Theme.selectedSurface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resume monitoring")
        } else {
            Menu {
                Button("15 minutes") { viewModel.pause(for: 15 * 60) }
                Button("30 minutes") { viewModel.pause(for: 30 * 60) }
                Button("1 hour") { viewModel.pause(for: 60 * 60) }
                Divider()
                Button("Until resumed") { viewModel.pause(for: nil) }
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: iconSize, height: iconSize)
                    .contentShape(Rectangle())
                    .background(Theme.selectedSurface)
                    .clipShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Pause monitoring")
            .accessibilityHint("Opens menu to choose pause duration")
        }
    }
}
