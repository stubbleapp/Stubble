import AppKit
import TaskMinerShared

/// NSApplicationDelegate that owns the menu bar status item.
/// Using @NSApplicationDelegateAdaptor ensures this object lives for the entire app lifecycle.
@MainActor
final class MenuBarDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var pauseController: PauseController?
    private var pollTimer: Timer?
    private var permissionPollTimer: Timer?
    private var daemonProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.enableFileLogging()

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

        // Defer permissions + daemon until after the setup wizard completes.
        // The wizard has its own permissions page and the daemon triggers
        // the Screen Recording system dialog — both are confusing during setup.
        if SettingsManager.shared.hasCompletedSetup {
            requestPermissionsIfNeeded()
            startDaemon()
        } else {
            // Listen for wizard completion to start daemon + check permissions
            NotificationCenter.default.addObserver(
                forName: .setupWizardCompleted, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.requestPermissionsIfNeeded()
                    self?.startDaemon()
                }
            }
        }

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
        pollTimer?.invalidate()
        pollTimer = nil
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        stopDaemon()
    }

    // MARK: - Permissions

    /// Check permissions on every launch. If missing, show an alert directing the
    /// user to System Settings and open the relevant pane. Polls until granted,
    /// then restarts the daemon so it picks up the new TCC grants.
    private func requestPermissionsIfNeeded() {
        PermissionManager.requestAccessibilityAccess()

        Task { @MainActor in
            let status = await PermissionManager.currentStatus()

            Logger.info("Permission check at launch — Accessibility: \(status.accessibility ? "✅" : "❌"), Screen Recording: \(status.screenRecording ? "✅" : "❌")")

            guard !status.allGranted else { return }

            let missing = status.missingPermissions

            let alert = NSAlert()
            alert.messageText = "Stubble needs permissions"
            alert.informativeText = "Please grant \(missing.joined(separator: " and ")) in System Settings.\n\nIf Stubble is already in the list, remove it and re-add it (the app was updated)."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if !status.screenRecording {
                    PermissionManager.openScreenRecordingSettings()
                } else {
                    PermissionManager.openAccessibilitySettings()
                }
            }

            // Poll every 2 seconds until both are granted, then restart daemon
            permissionPollTimer?.invalidate()
            permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    let current = await PermissionManager.currentStatus()
                    if current.allGranted {
                        self?.permissionPollTimer?.invalidate()
                        self?.permissionPollTimer = nil
                        Logger.info("All permissions granted — restarting daemon to apply")
                        self?.stopDaemon()
                        self?.startDaemon()
                    }
                }
            }
        }
    }

    // MARK: - App Icon

    /// Set the Dock / app switcher icon from the bundled .icns file.
    /// Composites the icon onto a solid dark background so it doesn't appear transparent in the Dock.
    private func setAppIcon() {
        var rawIcon: NSImage?

        // 1) .app bundle — standard location
        if let bundlePath = Bundle.main.path(forResource: "AppIcon", ofType: "icns") {
            rawIcon = NSImage(contentsOfFile: bundlePath)
        }

        // 2) Development — look relative to the binary's package checkout
        if rawIcon == nil {
            let binaryPath = ProcessInfo.processInfo.arguments[0]
            let binaryDir = (binaryPath as NSString).deletingLastPathComponent
            for ancestor in ["../../..", "../../../.."] {
                let candidate = (binaryDir as NSString).appendingPathComponent("\(ancestor)/Resources/AppIcon.icns")
                let resolved = (candidate as NSString).standardizingPath
                if FileManager.default.fileExists(atPath: resolved) {
                    rawIcon = NSImage(contentsOfFile: resolved)
                    if rawIcon != nil { break }
                }
            }
        }

        guard let icon = rawIcon else { return }

        // Composite onto an off-white rounded-rect background matching the app's warm cream theme
        let size: CGFloat = 1024
        let composited = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Off-white background matching the app's warm cream palette (RGB ~247,247,243)
            let bgColor = CGColor(red: 0.969, green: 0.969, blue: 0.953, alpha: 1.0)
            let cornerRadius = size * 0.22 // macOS squircle-like rounding
            let bgPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ctx.addPath(bgPath)
            ctx.setFillColor(bgColor)
            ctx.fillPath()

            // Draw the original icon on top
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }

        NSApp.applicationIconImage = composited
    }

    // MARK: - Menu Bar Icon

    /// Draw a small radial gradient dot for the menu bar.
    /// Marked as a template image so macOS renders it in the system's
    /// menu bar style (white/dark automatically matching other icons).
    private func makeMenuBarIcon() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = size / 2

            // Radial gradient from solid black center to transparent edge.
            // As a template image, macOS maps black → menu bar foreground color
            // and transparent → clear, matching the system appearance automatically.
            let colors = [
                CGColor(gray: 0.0, alpha: 1.0),
                CGColor(gray: 0.0, alpha: 0.55),
                CGColor(gray: 0.0, alpha: 0.0),
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
        image.isTemplate = true
        return image
    }

    // MARK: - Daemon Lifecycle

    /// Starts the daemon as a child process using the SAME Stubble binary with --daemon.
    /// This is critical: macOS TCC (Screen Recording, Accessibility) grants permission
    /// per executable path. Using the same binary path means the daemon inherits the
    /// dashboard's permissions automatically — no need to grant twice.
    private func startDaemon() {
        let binaryPath = ProcessInfo.processInfo.arguments[0]

        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--daemon"]
        // Inherit the environment so Gemini key etc. are available
        process.environment = ProcessInfo.processInfo.environment

        // Don't let stdout/stderr from the daemon pollute the dashboard
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            daemonProcess = process
            Logger.info("Started daemon (PID \(process.processIdentifier))")
        } catch {
            Logger.error("Failed to start daemon: \(error.localizedDescription)")
        }
    }

    /// Gracefully stops the daemon when the dashboard quits.
    private func stopDaemon() {
        guard let process = daemonProcess, process.isRunning else { return }
        // Send SIGTERM for graceful shutdown (the daemon handles this)
        process.terminate()
        Logger.info("Stopped daemon")
        daemonProcess = nil
    }

    /// Rebuild the menu to reflect current pause state.
    private func rebuildMenu() {
        let menu = NSMenu()

        // Open dashboard
        let openItem = NSMenuItem(title: "Open Stubble", action: #selector(openApp), keyEquivalent: "o")
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
        let quitItem = NSMenuItem(title: "Quit Stubble", action: #selector(quitApp), keyEquivalent: "q")
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

// MARK: - Notifications

extension Notification.Name {
    /// Posted by the setup wizard when the user completes initial setup.
    static let setupWizardCompleted = Notification.Name("setupWizardCompleted")
}
