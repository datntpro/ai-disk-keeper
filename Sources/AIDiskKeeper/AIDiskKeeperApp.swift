import AIDiskKeeperUI
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Brings the window to the front under `swift run` (no bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

struct AIDiskKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env = AppEnvironment.live()

    var body: some Scene {
        WindowGroup("AI Disk Keeper") {
            RootView(env: env)
        }
        .defaultSize(width: 1200, height: 760)
        .commands { ScanCommands() }
    }
}
