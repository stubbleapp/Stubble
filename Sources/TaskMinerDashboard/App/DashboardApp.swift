import SwiftUI
import AppKit
import Sparkle
import TaskMinerShared

struct DashboardApp: App {
    @NSApplicationDelegateAdaptor(MenuBarDelegate.self) var appDelegate
    @State private var viewModel = DashboardViewModel()
    @State private var hasCompletedSetup = SettingsManager.shared.hasCompletedSetup
    @StateObject private var updater = SoftwareUpdater()

    init() {
        Analytics.initialize()
        Analytics.appLaunched()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedSetup {
                    ContentView()
                        .frame(minWidth: 600, minHeight: 400)
                } else {
                    SetupWizardView {
                        // Re-initialize Gemini client now that the key may have been saved
                        if let key = SettingsManager.shared.geminiApiKey {
                            viewModel.updateGeminiKey(key)
                        }
                        viewModel.loadDataForSelectedDate()
                        Analytics.setupCompleted()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            hasCompletedSetup = true
                        }
                    }
                }
            }
            .environment(viewModel)
            .environmentObject(updater)
            .tint(Theme.accent)
        }
        .defaultSize(width: hasCompletedSetup ? 1100 : 560, height: hasCompletedSetup ? 750 : 480)
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
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
        }
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
