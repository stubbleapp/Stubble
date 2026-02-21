import SwiftUI
import TaskMinerShared

@main
struct DashboardApp: App {
    @State private var viewModel = DashboardViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1100, height: 750)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
