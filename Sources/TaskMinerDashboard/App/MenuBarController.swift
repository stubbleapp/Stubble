import AppKit
import TaskMinerShared

/// NSApplicationDelegate that owns the menu bar status item.
/// Using @NSApplicationDelegateAdaptor ensures this object lives for the entire app lifecycle.
@MainActor
final class MenuBarDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var pauseController: PauseController?
    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the pause controller (same data directory as the dashboard)
        if let config = try? SharedConfiguration() {
            self.pauseController = PauseController(dataDirectory: config.dataDirectory)
        }

        // Create the status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: "TaskMiner")
            image?.isTemplate = true
            button.image = image
        }
        rebuildMenu()

        // Poll pause state every 2 seconds to keep the menu accurate
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildMenu()
            }
        }
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

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func openApp() {
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
