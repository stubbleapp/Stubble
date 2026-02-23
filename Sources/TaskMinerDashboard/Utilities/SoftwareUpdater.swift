import SwiftUI
import Sparkle
import TaskMinerShared

/// Observable wrapper around Sparkle's updater for SwiftUI integration.
/// Sparkle requires a proper .app bundle with Info.plist (SUFeedURL, etc.).
/// When running via `swift run` or from an IDE, the updater is disabled gracefully.
@MainActor
final class SoftwareUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController?

    @Published var canCheckForUpdates = false

    /// Whether we're running inside a .app bundle (Sparkle won't work without one).
    var isAvailable: Bool { updaterController != nil }

    /// Track whether the current check was user-initiated (manual).
    /// Errors are only shown for manual checks — background checks fail silently.
    private var isManualCheck = false

    override init() {
        super.init()

        // Only start Sparkle when running inside a real .app bundle.
        // Without a bundle, there's no Info.plist for SUFeedURL / SUPublicEDKey,
        // and Sparkle will log errors or crash.
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.infoDictionary?["SUFeedURL"] != nil else {
            self.updaterController = nil
            return
        }

        // Start with updater paused — we'll start it manually after configuration.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.updaterController = controller

        // Check for updates once daily in the background
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.updateCheckInterval = 86400 // 24 hours

        // Now start the updater (it won't auto-check due to the flag above)
        do {
            try controller.updater.start()
        } catch {
            Logger.warning("Sparkle updater failed to start: \(error.localizedDescription)")
            self.updaterController = nil
            return
        }

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        isManualCheck = true
        updaterController?.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    /// Allow Sparkle to proceed with the update check even if the feed is unreachable.
    /// For background checks, we suppress errors entirely.
    nonisolated func updater(_ updater: SPUUpdater, shouldAllowInsecureConnectionFor existingConnection: Bool) -> Bool {
        false  // always require HTTPS
    }

    /// Called when the updater encounters an error.
    /// Returning true allows the default error dialog; false suppresses it.
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Log the error regardless
        Logger.debug("Sparkle update check error: \(error.localizedDescription)")
    }

    /// Suppress error UI for background/automatic checks so that 404s from
    /// a missing feed don't bother the user.
    nonisolated func updater(_ updater: SPUUpdater, shouldShowUpdateAlertForScheduledUpdate item: SUAppcastItem, userInitiated: Bool) -> Bool {
        userInitiated
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
