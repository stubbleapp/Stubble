import Foundation
import AppKit
import TaskMinerShared

class ActivityMonitor {
    var onAppChanged: ((NSRunningApplication) -> Void)?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        Logger.debug("ActivityMonitor started")
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        Logger.debug("ActivityMonitor stopped")
    }

    func currentApp() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }
        Logger.debug("App activated: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "?"))")
        onAppChanged?(app)
    }
}
