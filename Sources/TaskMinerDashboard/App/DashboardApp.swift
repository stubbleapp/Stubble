import SwiftUI
import TaskMinerShared

@main
struct DashboardApp: App {
    @NSApplicationDelegateAdaptor(MenuBarDelegate.self) var appDelegate
    @State private var viewModel = DashboardViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .tint(Theme.accent)
                .frame(minWidth: 600, minHeight: 400)
        }
        .defaultSize(width: 1100, height: 750)
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
