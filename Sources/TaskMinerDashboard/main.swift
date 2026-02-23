import Foundation
import AppKit
import TaskMinerShared
import TaskMinerDaemon

// ─── Daemon mode ──────────────────────────────────────────────────────────────
// When the build script copies this binary as "StubbleDaemon", or when launched
// with --daemon, run the background monitoring loop instead of the SwiftUI GUI.
// Using the SAME binary for both means macOS Screen Recording permission (which
// is tied to the binary) covers both the dashboard and the daemon automatically.

let isDaemon = CommandLine.arguments.contains("--daemon")
    || ProcessInfo.processInfo.processName == "StubbleDaemon"

if isDaemon {
    DaemonMain.run()  // never returns
} else {
    DashboardApp.main()
}
