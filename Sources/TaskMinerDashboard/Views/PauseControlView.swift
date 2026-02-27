import SwiftUI
import TaskMinerShared

/// Pause/resume control for the toolbar — circular icon button with centered icon.
/// Uses a plain Button + NSMenu instead of SwiftUI Menu to guarantee pixel-perfect centering.
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
            // Active → button that opens an NSMenu for pause duration choices.
            Button {
                showPauseMenu()
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: iconSize, height: iconSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: iconSize, height: iconSize)
            .modifier(NoToolbarGlassModifier())
            .accessibilityLabel("Pause monitoring")
            .accessibilityHint("Opens menu to choose pause duration")
        }
    }

    private func showPauseMenu() {
        let menu = NSMenu()

        let item15 = NSMenuItem(title: "15 minutes", action: #selector(PauseMenuDelegate.pause15), keyEquivalent: "")
        let item30 = NSMenuItem(title: "30 minutes", action: #selector(PauseMenuDelegate.pause30), keyEquivalent: "")
        let item60 = NSMenuItem(title: "1 hour", action: #selector(PauseMenuDelegate.pause60), keyEquivalent: "")
        let itemForever = NSMenuItem(title: "Until resumed", action: #selector(PauseMenuDelegate.pauseForever), keyEquivalent: "")

        // Shared delegate that holds a weak ref to the viewModel
        let delegate = PauseMenuDelegate.shared
        delegate.viewModel = viewModel

        item15.target = delegate
        item30.target = delegate
        item60.target = delegate
        itemForever.target = delegate

        menu.addItem(item15)
        menu.addItem(item30)
        menu.addItem(item60)
        menu.addItem(.separator())
        menu.addItem(itemForever)

        // Pop up the menu at the mouse location
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// NSMenu action target — bridges NSMenu item clicks to the DashboardViewModel.
@MainActor
private class PauseMenuDelegate: NSObject {
    static let shared = PauseMenuDelegate()
    weak var viewModel: DashboardViewModel?

    @objc func pause15() { viewModel?.pause(for: 15 * 60) }
    @objc func pause30() { viewModel?.pause(for: 30 * 60) }
    @objc func pause60() { viewModel?.pause(for: 60 * 60) }
    @objc func pauseForever() { viewModel?.pause(for: nil) }
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
