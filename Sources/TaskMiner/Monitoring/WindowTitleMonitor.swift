import Foundation
import ApplicationServices
import TaskMinerShared

class WindowTitleMonitor {
    var onTitleChanged: ((String) -> Void)?

    private var currentPid: pid_t = 0
    private var currentTitle: String = ""
    private var observer: AXObserver?

    /// Call when the frontmost app changes
    func updateFocusedApp(pid: pid_t) {
        tearDownObserver()
        currentPid = pid
        setupObserver(pid: pid)

        // Immediately read the new app's window title
        if let title = readFocusedWindowTitle(pid: pid) {
            if title != currentTitle {
                currentTitle = title
                onTitleChanged?(title)
            }
        } else {
            currentTitle = ""
        }
    }

    /// Polling fallback — call from periodic timer
    func pollTitle() {
        guard currentPid != 0 else { return }
        if let title = readFocusedWindowTitle(pid: currentPid) {
            if title != currentTitle {
                currentTitle = title
                Logger.debug("Title changed (poll): \(title)")
                onTitleChanged?(title)
            }
        }
    }

    func stop() {
        tearDownObserver()
        currentPid = 0
        currentTitle = ""
    }

    var title: String { currentTitle }

    // MARK: - Accessibility API

    private func readFocusedWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let err1 = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow
        )
        guard err1 == .success, let ref = focusedWindow else { return nil }
        // CFTypeRef is type-erased; cast safely via the type-ID check.
        guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast — CFTypeRef bridging requires as!; guarded by type-ID check above
        let windowElement = unsafeBitCast(ref, to: AXUIElement.self)

        var titleValue: CFTypeRef?
        let err2 = AXUIElementCopyAttributeValue(
            windowElement, kAXTitleAttribute as CFString, &titleValue
        )
        guard err2 == .success, let title = titleValue as? String else { return nil }
        return title
    }

    // MARK: - AXObserver

    private func setupObserver(pid: pid_t) {
        var obs: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &obs)
        guard result == .success, let observer = obs else {
            Logger.debug("Could not create AXObserver for pid \(pid)")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let r1 = AXObserverAddNotification(
            observer, appElement,
            kAXFocusedWindowChangedNotification as CFString, refcon
        )
        let r2 = AXObserverAddNotification(
            observer, appElement,
            kAXTitleChangedNotification as CFString, refcon
        )

        // Only keep the observer if at least one notification registered
        guard r1 == .success || r2 == .success else {
            Logger.debug("AXObserver: both notifications failed for pid \(pid)")
            return
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        self.observer = observer
        Logger.debug("AXObserver set up for pid \(pid) (focus: \(r1 == .success), title: \(r2 == .success))")
    }

    private func tearDownObserver() {
        guard let observer = observer else { return }

        // Remove AX notification registrations to prevent leaked callbacks
        let appElement = AXUIElementCreateApplication(currentPid)
        AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
        AXObserverRemoveNotification(observer, appElement, kAXTitleChangedNotification as CFString)

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        self.observer = nil
    }
}

// C-level callback for AXObserver — must be a free function
private func axCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notificationName: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let monitor = Unmanaged<WindowTitleMonitor>.fromOpaque(refcon).takeUnretainedValue()
    // Re-read the title on any AX notification
    monitor.pollTitle()
}
