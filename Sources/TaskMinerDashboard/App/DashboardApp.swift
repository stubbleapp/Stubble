import SwiftUI
import AppKit
import ServiceManagement
import Sparkle
import TaskMinerShared

struct DashboardApp: App {
    @NSApplicationDelegateAdaptor(MenuBarDelegate.self) var appDelegate
    @State private var viewModel = DashboardViewModel()
    @State private var hasCompletedSetup = SettingsManager.shared.hasCompletedSetup
    @State private var appearanceMode = SettingsManager.shared.appearanceMode
    @StateObject private var updater = SoftwareUpdater()

    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Guard against SwiftUI calling init() multiple times on this struct.
    private static var didInitialize = false

    init() {
        guard !Self.didInitialize else { return }
        Self.didInitialize = true
        Theme.registerFonts()
        Analytics.initialize()
        Analytics.appLaunched()
        Self.ensureLaunchAtLogin()
    }

    /// Registers the login item if launch-at-login is enabled (default: true).
    /// Runs once per launch so existing users who never toggled the setting get it enabled.
    private static func ensureLaunchAtLogin() {
        guard SettingsManager.shared.launchAtLogin else { return }
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedSetup {
                    ContentView()
                        .frame(minWidth: 600, maxWidth: 1200, minHeight: 400, maxHeight: 850)
                } else {
                    SetupWizardView {
                        // Re-initialize Gemini client now that the key may have been saved
                        if let key = SettingsManager.shared.geminiApiKey {
                            viewModel.updateGeminiKey(key)
                        }
                        viewModel.loadDataForSelectedDate()
                        Analytics.setupCompleted()
                        // Notify MenuBarController to start daemon + check permissions
                        NotificationCenter.default.post(name: .setupWizardCompleted, object: nil)
                        withAnimation(.easeInOut(duration: 0.3)) {
                            hasCompletedSetup = true
                        }
                    }
                }
            }
            .environment(viewModel)
            .environmentObject(updater)
            .tint(Theme.accent)
            .preferredColorScheme(colorScheme)
            .onReceive(NotificationCenter.default.publisher(for: .appearanceModeChanged)) { _ in
                appearanceMode = SettingsManager.shared.appearanceMode
            }
        }
        .defaultSize(width: hasCompletedSetup ? 1100 : 560, height: hasCompletedSetup ? 750 : 480)
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("About Stubble") {
                    showAboutPanel()
                }
                Divider()
                if updater.isAvailable {
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton()
            }
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(viewModel)
                .tint(Theme.accent)
                .preferredColorScheme(colorScheme)
                .onReceive(NotificationCenter.default.publisher(for: .appearanceModeChanged)) { _ in
                    appearanceMode = SettingsManager.shared.appearanceMode
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 620, height: 480)
        .windowResizability(.contentSize)
    }

    private func showAboutPanel() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Stubble",
            .applicationVersion: version,
            .version: build,
            .credits: NSAttributedString(
                string: "A quiet desktop activity tracker.\nhttps://github.com/samattias",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        ])
    }
}

/// Menu button that opens the Settings window via `openWindow`.
/// Defined as a View so `@Environment(\.openWindow)` is available.
private struct OpenSettingsButton: View {
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Button("Settings\u{2026}") {
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
