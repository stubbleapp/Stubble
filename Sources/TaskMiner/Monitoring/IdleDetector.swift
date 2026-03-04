import Foundation
import AppKit
import CoreGraphics
import TaskMinerShared

class IdleDetector {
    private let threshold: TimeInterval
    private(set) var wasIdle: Bool = false

    /// Forced idle/active state from system events (screen lock, sleep, etc.)
    /// When non-nil, overrides the HID-based idle detection.
    private var systemForcedIdle: Bool?

    /// Called on the main thread when a system event forces an idle transition.
    /// The AppDelegate can hook this to react instantly rather than waiting
    /// for the next periodic poll.
    var onSystemIdleTransition: ((IdleTransition) -> Void)?

    /// Optional callback that returns true when the user is engaged in media/video calls.
    /// When this returns true, idle detection is suppressed (user is watching/listening).
    var isUserEngagedInMedia: (() -> Bool)?

    init(threshold: TimeInterval) {
        self.threshold = threshold
    }

    var isIdle: Bool {
        // System events (screen lock, sleep) take precedence
        if let forced = systemForcedIdle { return forced }

        // Media/video call engagement suppresses idle detection
        if isUserEngagedInMedia?() == true { return false }

        return idleTime >= threshold
    }

    var idleTime: TimeInterval {
        let mouseMove = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .mouseMoved
        )
        let keyDown = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .keyDown
        )
        let leftClick = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .leftMouseDown
        )
        let scrollWheel = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .scrollWheel
        )
        // User is idle only when ALL input types exceed threshold
        return min(mouseMove, keyDown, leftClick, scrollWheel)
    }

    /// Returns true if idle state transitioned since last check
    func checkTransition() -> IdleTransition {
        let currentlyIdle = isIdle
        defer { wasIdle = currentlyIdle }

        if !wasIdle && currentlyIdle {
            return .becameIdle
        } else if wasIdle && !currentlyIdle {
            return .becameActive
        }
        return .noChange
    }

    // MARK: - System Event Observers

    /// Start observing macOS system events that indicate the user is AFK.
    /// Call once from AppDelegate.start().
    func startSystemEventObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        // Sleep / Wake
        ws.addObserver(self, selector: #selector(handleSystemSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSystemWake),
                       name: NSWorkspace.didWakeNotification, object: nil)

        // Session resign / activate (fast user switching, logout)
        ws.addObserver(self, selector: #selector(handleSessionResign),
                       name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSessionActivate),
                       name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        // Screen lock / unlock
        dnc.addObserver(self, selector: #selector(handleScreenLocked),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(handleScreenUnlocked),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)

        // Screensaver start / stop
        dnc.addObserver(self, selector: #selector(handleScreensaverStart),
                        name: NSNotification.Name("com.apple.screensaver.didStart"), object: nil)
        dnc.addObserver(self, selector: #selector(handleScreensaverStop),
                        name: NSNotification.Name("com.apple.screensaver.didStop"), object: nil)

        Logger.info("System event observers started (sleep/wake, lock/unlock, session, screensaver)")
    }

    /// Remove all observers. Call from AppDelegate.shutdown().
    func stopSystemEventObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - System Idle (AFK)

    @objc private func handleSystemSleep(_ notification: Notification) {
        Logger.info("System going to sleep — marking user idle")
        forceIdle()
    }

    @objc private func handleSessionResign(_ notification: Notification) {
        Logger.info("Session resigned (fast user switch / logout) — marking user idle")
        forceIdle()
    }

    @objc private func handleScreenLocked(_ notification: Notification) {
        Logger.info("Screen locked — marking user idle")
        forceIdle()
    }

    @objc private func handleScreensaverStart(_ notification: Notification) {
        Logger.info("Screensaver started — marking user idle")
        forceIdle()
    }

    // MARK: - System Active (returned)

    @objc private func handleSystemWake(_ notification: Notification) {
        Logger.info("System woke up — marking user active")
        forceActive()
    }

    @objc private func handleSessionActivate(_ notification: Notification) {
        Logger.info("Session became active — marking user active")
        forceActive()
    }

    @objc private func handleScreenUnlocked(_ notification: Notification) {
        Logger.info("Screen unlocked — marking user active")
        forceActive()
    }

    @objc private func handleScreensaverStop(_ notification: Notification) {
        Logger.info("Screensaver stopped — marking user active")
        forceActive()
    }

    // MARK: - Force Helpers

    private func forceIdle() {
        // DistributedNotificationCenter delivers on the posting thread (not
        // guaranteed main). Dispatch to main to avoid data races on
        // systemForcedIdle/wasIdle and to satisfy the dispatchPrecondition
        // assertions in AppDelegate's handleIdleTransition.
        let work = {
            guard self.systemForcedIdle != true else { return }
            self.systemForcedIdle = true
            let transition = self.checkTransition()
            if transition == .becameIdle {
                self.onSystemIdleTransition?(transition)
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func forceActive() {
        let work = {
            self.systemForcedIdle = nil // clear override, let HID polling take over
            let transition = self.checkTransition()
            if transition == .becameActive {
                self.onSystemIdleTransition?(transition)
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    enum IdleTransition: Equatable {
        case becameIdle
        case becameActive
        case noChange
    }
}
