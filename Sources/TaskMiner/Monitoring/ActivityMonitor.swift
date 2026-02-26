import Foundation
import AppKit
import TaskMinerShared

class ActivityMonitor {
    var onAppChanged: ((NSRunningApplication) -> Void)?
    /// Called when an app launches (not just activates). Provides the app for context logging.
    var onAppLaunched: ((NSRunningApplication) -> Void)?
    /// Called when an app terminates.
    var onAppTerminated: ((NSRunningApplication) -> Void)?

    /// Set of bundle IDs launched during this session (for dedup / tracking).
    private(set) var launchedApps: Set<String> = []

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        Logger.debug("ActivityMonitor started (activation + launch/terminate)")
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        Logger.debug("ActivityMonitor stopped")
    }

    func currentApp() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    /// Returns the list of app names launched today (useful for summarization context).
    func launchedAppNames() -> [String] {
        Array(launchedApps)
    }

    /// Reset tracked launches (call at midnight rollover).
    func resetLaunchedApps() {
        launchedApps.removeAll()
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }
        Logger.debug("App activated: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "?"))")
        onAppChanged?(app)
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }
        if let bundleId = app.bundleIdentifier {
            launchedApps.insert(bundleId)
        }
        Logger.debug("App launched: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "?"))")
        onAppLaunched?(app)
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }
        Logger.debug("App terminated: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "?"))")
        onAppTerminated?(app)
    }
}
