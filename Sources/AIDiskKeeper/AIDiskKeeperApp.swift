import AIDiskKeeperUI
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the App: true while the menu bar item is shown, so closing the window keeps the app (and its poll) alive.
    nonisolated(unsafe) static var keepRunningWithoutWindows: @MainActor () -> Bool = { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.keepRunningWithoutWindows()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Brings the window to the front under `swift run` (no bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

struct AIDiskKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var models: AppModels

    init() {
        let models = AppModels.live()
        _models = State(initialValue: models)
        AppDelegate.keepRunningWithoutWindows = { models.env.settings.settings.showMenuBarItem }
    }

    var body: some Scene {
        mainScenes
        menuBarScene
    }
}

extension AIDiskKeeperApp {
    @SceneBuilder private var mainScenes: some Scene {
        let _ = models.env.settings.languageRevision   // re-evaluate menus (Scan menu title, shortcuts) after a language switch
        Window(Text(verbatim: "AI Disk Keeper"), id: "main") {
            RootView(models: models)
        }
        .defaultSize(width: 1200, height: 760)
        .commands { ScanCommands() }
        Settings { SettingsView(model: models.env.settings) }
    }

    @SceneBuilder private var menuBarScene: some Scene {
        MenuBarExtra(isInserted: models.menuBarInserted) {
            models.menuBarPopover
        } label: {
            models.menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }
}
