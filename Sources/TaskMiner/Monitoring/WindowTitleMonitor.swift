import Foundation
import ApplicationServices
import TaskMinerShared

/// Extended context gathered from Accessibility APIs beyond just the window title.
struct AXContext {
    var windowTitle: String?
    /// AX role of the focused UI element (e.g. "AXTextField", "AXWebArea").
    var focusedElementRole: String?
    /// Document path from kAXDocumentAttribute (editors, Preview, etc.).
    var documentPath: String?
    /// Browser address bar URL (Safari, Chrome, Arc, Brave, etc.).
    var browserURL: String?
}

class WindowTitleMonitor {
    var onTitleChanged: ((String) -> Void)?

    private var currentPid: pid_t = 0
    private var currentTitle: String = ""
    private var observer: AXObserver?

    /// The most recently captured extended AX context. Read by AppDelegate
    /// when creating a new ActivityRecord to populate the extra fields.
    private(set) var lastContext = AXContext()

    /// Bundle IDs of known browser apps for URL bar extraction.
    private static let browserBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "company.thebrowser.Browser",      // Arc
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// The bundle ID of the current frontmost app — set by AppDelegate.
    var currentBundleId: String?

    /// Call when the frontmost app changes
    func updateFocusedApp(pid: pid_t) {
        tearDownObserver()
        currentPid = pid
        setupObserver(pid: pid)

        // Immediately read the new app's window title + extended context
        let ctx = readFullContext(pid: pid)
        lastContext = ctx
        if let title = ctx.windowTitle, title != currentTitle {
            currentTitle = title
            onTitleChanged?(title)
        } else if ctx.windowTitle == nil {
            currentTitle = ""
        }
    }

    /// Polling fallback — call from periodic timer
    func pollTitle() {
        guard currentPid != 0 else { return }
        let ctx = readFullContext(pid: currentPid)
        lastContext = ctx
        if let title = ctx.windowTitle, title != currentTitle {
            currentTitle = title
            Logger.debug("Title changed (poll): \(title)")
            onTitleChanged?(title)
        }
    }

    deinit {
        tearDownObserver()
    }

    func stop() {
        tearDownObserver()
        currentPid = 0
        currentTitle = ""
        lastContext = AXContext()
    }

    var title: String { currentTitle }

    // MARK: - Accessibility API

    /// Read the full AX context: window title, focused element role, document path, and browser URL.
    private func readFullContext(pid: pid_t) -> AXContext {
        var ctx = AXContext()

        let appElement = AXUIElementCreateApplication(pid)

        // 1. Window title (existing logic)
        var focusedWindow: CFTypeRef?
        let err1 = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow
        )
        var windowElement: AXUIElement?
        if err1 == .success, let ref = focusedWindow,
           CFGetTypeID(ref) == AXUIElementGetTypeID() {
            windowElement = unsafeBitCast(ref, to: AXUIElement.self)

            var titleValue: CFTypeRef?
            let err2 = AXUIElementCopyAttributeValue(
                windowElement!, kAXTitleAttribute as CFString, &titleValue
            )
            if err2 == .success, let title = titleValue as? String {
                ctx.windowTitle = title
            }

            // 2. Document path from the window (works in Xcode, TextEdit, Preview, etc.)
            var docValue: CFTypeRef?
            let err3 = AXUIElementCopyAttributeValue(
                windowElement!, kAXDocumentAttribute as CFString, &docValue
            )
            if err3 == .success, let urlStr = docValue as? String {
                // kAXDocumentAttribute returns a file URL string like "file:///Users/..."
                if let url = URL(string: urlStr), url.isFileURL {
                    ctx.documentPath = url.path
                } else {
                    ctx.documentPath = urlStr
                }
            }
        }

        // 3. Focused UI element role
        var focusedElement: CFTypeRef?
        let err4 = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement
        )
        if err4 == .success, let ref = focusedElement,
           CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let element = unsafeBitCast(ref, to: AXUIElement.self)

            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String {
                ctx.focusedElementRole = role
            }
        }

        // 4. Browser URL — read the address bar value for known browsers
        if let bundleId = currentBundleId, Self.browserBundleIds.contains(bundleId) {
            ctx.browserURL = readBrowserURL(appElement: appElement, bundleId: bundleId)
        }

        return ctx
    }

    /// Best-effort extraction of the current URL from a browser's address bar via AX.
    private func readBrowserURL(appElement: AXUIElement, bundleId: String) -> String? {
        // Strategy: find the focused window, then search for a text field with role "AXTextField"
        // whose value looks like a URL. Safari uses "AXTextField" for the address bar.
        // Chrome/Brave use "AXTextField" inside a "AXToolbar" or "AXGroup".
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow
        ) == .success, let ref = focusedWindow,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }

        let window = unsafeBitCast(ref, to: AXUIElement.self)

        // For Safari, the address bar is directly accessible via kAXFocusedUIElement on the toolbar,
        // or we can traverse children. For performance, limit the search depth.
        if let url = findURLTextField(in: window, depth: 0, maxDepth: 6) {
            return url
        }
        return nil
    }

    /// Recursively search for a text field whose value looks like a URL.
    /// Stops at maxDepth to avoid excessive AX tree traversal.
    private func findURLTextField(in element: AXUIElement, depth: Int, maxDepth: Int) -> String? {
        guard depth < maxDepth else { return nil }

        // Check if this element is a text field with a URL-like value
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, role == "AXTextField" {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
               let value = valueRef as? String {
                // Heuristic: URL bars contain "." and are typically ≤ 2048 chars
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed.count < 2048 && trimmed.contains(".") {
                    // Check for description attribute hinting this is an address bar
                    var descRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef) == .success,
                       let desc = descRef as? String {
                        let lower = desc.lowercased()
                        if lower.contains("address") || lower.contains("url") || lower.contains("location") || lower.contains("search") {
                            return normalizeURL(trimmed)
                        }
                    }
                    // Fallback: if the value looks like a URL, accept it
                    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("www.") {
                        return normalizeURL(trimmed)
                    }
                }
            }
        }

        // Recurse into children
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        // Limit scan to first 20 children to stay fast
        for child in children.prefix(20) {
            if let url = findURLTextField(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return url
            }
        }
        return nil
    }

    /// Normalize URL: add https:// prefix if missing, strip query/fragment for privacy.
    private func normalizeURL(_ raw: String) -> String {
        var url = raw
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://" + url
        }
        // Strip query parameters and fragments — they may contain sensitive data
        if let qIndex = url.firstIndex(of: "?") { url = String(url[..<qIndex]) }
        if let fIndex = url.firstIndex(of: "#") { url = String(url[..<fIndex]) }
        return url
    }

    /// Legacy: read just the window title (kept for compatibility).
    private func readFocusedWindowTitle(pid: pid_t) -> String? {
        readFullContext(pid: pid).windowTitle
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
