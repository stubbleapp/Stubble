import AppKit
import TaskMinerShared

/// NSApplicationDelegate that owns the menu bar status item.
/// Using @NSApplicationDelegateAdaptor ensures this object lives for the entire app lifecycle.
@MainActor
final class MenuBarDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var pauseController: PauseController?
    private var pollTimer: Timer?
    private var daemonProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched via `swift run` or from an IDE (Cursor, Xcode, etc.) the process
        // has no .app bundle, so macOS defaults it to an activation policy that does NOT
        // grant keyboard focus. Setting .regular tells macOS this is a normal foreground
        // app that should receive key events, appear in the Dock, and own the menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Set app icon — when running from .app bundle it's in Resources/;
        // when running via `swift run` we look relative to the package root.
        setAppIcon()

        // Create the pause controller (same data directory as the dashboard)
        if let config = try? SharedConfiguration() {
            self.pauseController = PauseController(dataDirectory: config.dataDirectory)
        }

        // Start the monitoring daemon (bundled alongside the dashboard binary)
        startDaemon()

        // Create the status item with our orange gradient icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeMenuBarIcon()
        }
        rebuildMenu()

        // Poll pause state every 2 seconds to keep the menu accurate
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopDaemon()
    }

    // MARK: - App Icon

    /// Set the Dock / app switcher icon from the bundled .icns file.
    private func setAppIcon() {
        // 1) .app bundle — standard location
        if let bundlePath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: bundlePath) {
            NSApp.applicationIconImage = icon
            return
        }

        // 2) Development — look relative to the binary's package checkout
        //    e.g. <repo>/.build/debug/TaskMinerDashboard → <repo>/Resources/AppIcon.icns
        let binaryPath = ProcessInfo.processInfo.arguments[0]
        let binaryDir = (binaryPath as NSString).deletingLastPathComponent
        // Walk up from .build/arm64-apple-macosx/debug to the package root
        for ancestor in ["../../..", "../../../.."] {
            let candidate = (binaryDir as NSString).appendingPathComponent("\(ancestor)/Resources/AppIcon.icns")
            let resolved = (candidate as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: resolved),
               let icon = NSImage(contentsOfFile: resolved) {
                NSApp.applicationIconImage = icon
                return
            }
        }
    }

    // MARK: - Menu Bar Icon

    /// Draw a small orange radial gradient circle for the menu bar.
    private func makeMenuBarIcon() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = size / 2

            // Orange radial gradient matching the app icon
            let colors = [
                CGColor(red: 0.91, green: 0.36, blue: 0.18, alpha: 1.0),
                CGColor(red: 0.95, green: 0.55, blue: 0.35, alpha: 0.6),
                CGColor(red: 1.0, green: 0.75, blue: 0.55, alpha: 0.0),
            ] as CFArray
            let locations: [CGFloat] = [0.0, 0.55, 1.0]

            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors,
                                            locations: locations) else { return false }

            ctx.drawRadialGradient(gradient,
                                   startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius,
                                   options: [])
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Daemon Lifecycle

    /// Starts the TaskMinerDaemon process bundled inside the .app.
    /// If running from `swift run` (no bundle), this is a no-op — the user runs the CLI manually.
    private func startDaemon() {
        // Look for the daemon binary next to the dashboard binary
        let dashboardPath = ProcessInfo.processInfo.arguments[0]
        let dashboardDir = (dashboardPath as NSString).deletingLastPathComponent
        let daemonPath = (dashboardDir as NSString).appendingPathComponent("TaskMinerDaemon")

        guard FileManager.default.isExecutableFile(atPath: daemonPath) else {
            // Not bundled (e.g. running via `swift run`) — skip
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonPath)
        process.arguments = []
        // Inherit the environment so Gemini key etc. are available
        process.environment = ProcessInfo.processInfo.environment

        // Don't let stdout/stderr from the daemon pollute the dashboard
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            daemonProcess = process
            Logger.info("Started TaskMinerDaemon (PID \(process.processIdentifier))")
        } catch {
            Logger.error("Failed to start TaskMinerDaemon: \(error.localizedDescription)")
        }
    }

    /// Gracefully stops the daemon when the dashboard quits.
    private func stopDaemon() {
        guard let process = daemonProcess, process.isRunning else { return }
        // Send SIGTERM for graceful shutdown (the daemon handles this)
        process.terminate()
        Logger.info("Stopped TaskMinerDaemon")
        daemonProcess = nil
    }

    /// Rebuild the menu to reflect current pause state.
    private func rebuildMenu() {
        let menu = NSMenu()

        // Open dashboard
        let openItem = NSMenuItem(title: "Open TaskMiner", action: #selector(openApp), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // Pause / Resume
        let isPaused = pauseController?.isPaused ?? false

        if isPaused {
            let resumeItem = NSMenuItem(title: "Resume Monitoring", action: #selector(resumeMonitoring), keyEquivalent: "")
            resumeItem.target = self
            resumeItem.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            menu.addItem(resumeItem)

            if let remaining = pauseController?.currentState()?.timeRemaining, remaining > 0 {
                let mins = Int(remaining) / 60
                let label = mins > 0 ? "Paused (\(mins) min remaining)" : "Paused"
                let infoItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                infoItem.isEnabled = false
                menu.addItem(infoItem)
            }
        } else {
            let pauseMenu = NSMenu()

            let p15 = NSMenuItem(title: "15 minutes", action: #selector(pause15), keyEquivalent: "")
            p15.target = self
            pauseMenu.addItem(p15)

            let p30 = NSMenuItem(title: "30 minutes", action: #selector(pause30), keyEquivalent: "")
            p30.target = self
            pauseMenu.addItem(p30)

            let p60 = NSMenuItem(title: "1 hour", action: #selector(pause60), keyEquivalent: "")
            p60.target = self
            pauseMenu.addItem(p60)

            pauseMenu.addItem(NSMenuItem.separator())

            let pIndef = NSMenuItem(title: "Until resumed", action: #selector(pauseIndefinite), keyEquivalent: "")
            pIndef.target = self
            pauseMenu.addItem(pIndef)

            let pauseItem = NSMenuItem(title: "Pause Monitoring", action: nil, keyEquivalent: "")
            pauseItem.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
            pauseItem.submenu = pauseMenu
            menu.addItem(pauseItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit TaskMiner", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func openApp() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Open or bring the main window to front
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func resumeMonitoring() {
        pauseController?.resume()
        rebuildMenu()
    }

    @objc private func pause15() {
        pauseController?.pause(for: 15 * 60)
        rebuildMenu()
    }

    @objc private func pause30() {
        pauseController?.pause(for: 30 * 60)
        rebuildMenu()
    }

    @objc private func pause60() {
        pauseController?.pause(for: 60 * 60)
        rebuildMenu()
    }

    @objc private func pauseIndefinite() {
        pauseController?.pause(for: nil)
        rebuildMenu()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
