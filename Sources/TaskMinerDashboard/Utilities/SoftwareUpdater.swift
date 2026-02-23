import SwiftUI
import Sparkle

/// Observable wrapper around Sparkle's updater for SwiftUI integration.
/// Sparkle requires a proper .app bundle with Info.plist (SUFeedURL, etc.).
/// When running via `swift run` or from an IDE, the updater is disabled gracefully.
@MainActor
final class SoftwareUpdater: ObservableObject {
    private var updaterController: SPUStandardUpdaterController?

    @Published var canCheckForUpdates = false

    /// Whether we're running inside a .app bundle (Sparkle won't work without one).
    var isAvailable: Bool { updaterController != nil }

    init() {
        // Only start Sparkle when running inside a real .app bundle.
        // Without a bundle, there's no Info.plist for SUFeedURL / SUPublicEDKey,
        // and Sparkle will log errors or crash.
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.infoDictionary?["SUFeedURL"] != nil else {
            self.updaterController = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = controller

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}

/// A "Check for Updates" button that integrates with Sparkle.
/// Hidden entirely when Sparkle is unavailable (e.g. running from IDE).
struct CheckForUpdatesView: View {
    @ObservedObject var updater: SoftwareUpdater

    var body: some View {
        if updater.isAvailable {
            Button {
                updater.checkForUpdates()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                    Text("Check for Updates")
                        .font(.system(size: 13))
                }
                .foregroundStyle(updater.canCheckForUpdates ? Theme.textPrimary : Theme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
