import SwiftUI
import Sparkle
import TaskMinerShared

@main
struct DashboardApp: App {
    @NSApplicationDelegateAdaptor(MenuBarDelegate.self) var appDelegate
    @State private var viewModel = DashboardViewModel()
    @State private var hasCompletedSetup = SettingsManager.shared.hasCompletedSetup
    @StateObject private var updater = SoftwareUpdater()

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedSetup {
                    ContentView()
                        .frame(minWidth: 600, minHeight: 400)
                } else {
                    SetupWizardView {
                        // Re-initialize Gemini client now that the key may have been saved
                        if let key = GeminiKeychain.get() {
                            viewModel.updateGeminiKey(key)
                        }
                        viewModel.loadDataForSelectedDate()
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
            CommandGroup(after: .appInfo) {
                if updater.isAvailable {
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
    }
}
