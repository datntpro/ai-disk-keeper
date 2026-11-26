import AppKit
import Foundation
import Observation
import SwiftUI

/// The window-independent models, created once by the App and shared by the window and the menu bar, so the popover
/// shows the same scan, care results and volume as the window and keeps working when the window is closed.
@MainActor
public final class AppModels {
    public let env: AppEnvironment
    public let scan: ScanViewModel
    public let suite: SuiteModel
    let cleanupSelection: SelectionModel
    let menuBar: MenuBarModel

    /// Used by `RootView(env:)` (tests): nothing is posted and nothing polls.
    public convenience init(env: AppEnvironment) {
        self.init(env: env, notifier: SilentLowSpaceNotifier(), defaults: .standard)
    }

    init(env: AppEnvironment, notifier: any LowSpaceNotifying, defaults: UserDefaults) {
        self.env = env
        let scan = ScanViewModel(makeEngine: env.makeScanEngine)
        let suite = SuiteModel(env: env)
        self.scan = scan
        self.suite = suite
        self.cleanupSelection = SelectionModel()
        self.menuBar = MenuBarModel(
            storage: StorageModule.model(env: env, suite: suite),
            care: OverviewModule.careModel(env: env, scan: scan, suite: suite),
            scan: scan, settings: env.settings, notifier: notifier, defaults: defaults)
    }

    /// The real app: live environment, real notifications, and the 60 s volume poll running.
    public static func live() -> AppModels {
        let notifier = LiveLowSpaceNotifier()
        let models = AppModels(env: .live(), notifier: notifier, defaults: .standard)
        notifier.onOpen = { [suite = models.suite] in
            suite.navigation.selection = .overview
            NSApp.activate()
        }
        models.menuBar.start()
        return models
    }
}

// The menu bar's views are internal to the UI module; the App target gets them as opaque views.
extension AppModels {
    public var menuBarInserted: Binding<Bool> { MenuBarModel.insertedBinding(env.settings) }
    public var menuBarPopover: some View { MenuBarPopover(model: menuBar, suite: suite) }
    public var menuBarLabel: some View { MenuBarLabel(model: menuBar) }
}
