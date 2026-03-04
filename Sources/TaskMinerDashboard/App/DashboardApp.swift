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
    /// Only runs after setup is complete to avoid registering before user opts in.
    private static func ensureLaunchAtLogin() {
        guard SettingsManager.shared.hasCompletedSetup else { return }
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
                        // Re-initialize Gemini client — could be BYOK key or proxy-mode auth
                        if AuthManager.shared.isSignedIn {
                            viewModel.refreshForAuthChange()
                        } else if let key = SettingsManager.shared.geminiApiKey {
                            viewModel.updateGeminiKey(key)
                        }
                        // Create onboarding task so timeline isn't empty
                        viewModel.createOnboardingTask()
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
            .onOpenURL { url in
                // Handle OAuth callback from Supabase Google sign-in
                if url.scheme == StubbleAPIConfig.callbackScheme && url.host == "auth-callback" {
                    Task {
                        let handled = await AuthManager.shared.handleCallback(url: url)
                        if handled {
                            // Auth state changed — reinitialize GeminiClient for proxy mode
                            viewModel.refreshForAuthChange()
                        }
                    }
                    return
                }

                // Handle chat deep link from notifications: com.stubble://chat?prompt=...
                if url.host == "chat" {
                    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let promptParam = components.queryItems?.first(where: { $0.name == "prompt" }),
                       let prompt = promptParam.value?.removingPercentEncoding,
                       !prompt.isEmpty {
                        viewModel.pendingChatQuestion = prompt
                        viewModel.shouldExpandChatPanel = true
                        // Post notification to switch to Chat tab (ContentView listens)
                        NotificationCenter.default.post(name: .switchToChatTab, object: nil)
                    }
                    return
                }

                // Handle subscription activation from Paddle checkout success page
                // com.stubble://subscription-activated
                if url.host == "subscription-activated" {
                    Task {
                        // Refresh session to pick up new subscription_tier from JWT
                        try? await AuthManager.shared.refreshSession()
                        viewModel.refreshForAuthChange()
                    }
                    return
                }

                // Fallback: try auth callback handling
                Task {
                    let handled = await AuthManager.shared.handleCallback(url: url)
                    if handled {
                        viewModel.refreshForAuthChange()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .authStateChanged)) { _ in
                viewModel.refreshForAuthChange()
            }
        }
        .defaultSize(width: hasCompletedSetup ? 1100 : 560, height: hasCompletedSetup ? 750 : 480)
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                AboutSettingsButton()
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
                .environmentObject(updater)
                .tint(Theme.accent)
                .preferredColorScheme(colorScheme)
                .onReceive(NotificationCenter.default.publisher(for: .appearanceModeChanged)) { _ in
                    appearanceMode = SettingsManager.shared.appearanceMode
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 620, height: 480)
        .windowResizability(.contentSize)
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

/// "About Stubble" menu item — opens Settings on the About tab.
private struct AboutSettingsButton: View {
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Button("About Stubble") {
            openWindow(id: "settings")
            // Give the window a moment to appear, then switch to About tab
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .showAboutInSettings, object: nil)
            }
        }
    }
}
