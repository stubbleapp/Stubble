import SwiftUI
import TaskMinerShared

private let pauseButtonHeight: CGFloat = 28
private let pauseLabelPaddingH: CGFloat = 12
private let pauseLabelPaddingV: CGFloat = 5

/// Pause/resume control for the toolbar — pill style, HIG-aligned height and padding.
struct PauseControlView: View {
    @Environment(DashboardViewModel.self) var viewModel

    var body: some View {
        if viewModel.pauseState != nil {
            Button(action: { viewModel.resumeMonitoring() }) {
                Label("Resume", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, pauseLabelPaddingH)
                    .padding(.vertical, pauseLabelPaddingV)
                    .frame(height: pauseButtonHeight)
                    .contentShape(Capsule())
                    .background(Theme.selectedSurface)
                    .clipShape(Capsule())
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
                Label("Pause", systemImage: "pause.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, pauseLabelPaddingH)
                    .padding(.vertical, pauseLabelPaddingV)
                    .frame(height: pauseButtonHeight)
                    .contentShape(Capsule())
                    .background(Theme.selectedSurface)
                    .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Pause monitoring")
            .accessibilityHint("Opens menu to choose pause duration")
        }
    }
}
