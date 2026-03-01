import Foundation
import AppKit
import TaskMinerShared

class ActivityMonitor {
    var onAppChanged: ((NSRunningApplication) -> Void)?

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
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }
        Logger.debug("App terminated: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "?"))")
    }
}
