import AppKit
import DiskKeeperCore
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
    let monitor: SystemMonitorModel
    let scheduler: MonitorScheduler
    let hostLoad: DiskActivityModel
    let hostStatus: HostStatusPublisher
    let scheduledScans: ScheduledScanController

    /// Used by `RootView(env:)` (tests): nothing is posted and nothing polls.
    public convenience init(env: AppEnvironment) {
        self.init(env: env, notifier: SilentLowSpaceNotifier(), defaults: .standard)
    }

    init(env: AppEnvironment, notifier: any AppNotifying, defaults: UserDefaults) {
        self.env = env
        let scan = ScanViewModel(makeEngine: env.makeScanEngine)
        let suite = SuiteModel(env: env)
        self.scan = scan
        self.suite = suite
        self.cleanupSelection = SelectionModel()
        self.menuBar = MenuBarModel(
            storage: StorageModule.model(env: env, suite: suite),
            care: OverviewModule.careModel(env: env, scan: scan, suite: suite),
            scan: scan, settings: env.settings, notifier: notifier, defaults: defaults,
            historyStore: FreeSpaceHistoryStore(fileURL: FreeSpaceHistoryStore.defaultFileURL(environment: env.pathEnvironment)))
        self.monitor = SystemMonitorModel(settings: env.settings, menuBar: menuBar)
        self.hostLoad = DiskActivityModule.model(env: env, suite: suite)
        let menuBar = menuBar
        self.scheduledScans = ScheduledScanController(
            settings: env.settings, runner: OverviewModule.careModel(env: env, scan: scan, suite: suite), notifier: notifier,
            // A scheduled run waits while a cleanup is open or running, and while the user has items ticked: starting
            // a scan bumps the scan generation, which clears the selection (invariant 18, T22 B1/B2).
            isBusy: { [cleanup = suite.cleanup, selection = cleanupSelection] in cleanup.isPresented || !selection.selectedIDs.isEmpty },
            onNextRun: { menuBar.nextScheduledScan = $0 })
        self.scheduler = MonitorScheduler(monitor: monitor, menuBar: menuBar, settings: env.settings, hostLoad: hostLoad)
        self.hostStatus = HostStatusPublisher.make(env: env)
    }

    /// The real app: live environment, real notifications, and the one monitor scheduler running (it also drives the 60 s volume poll).
    public static func live() -> AppModels {
        let notifier = LiveLowSpaceNotifier()
        let models = AppModels(env: .live(), notifier: notifier, defaults: .standard)
        notifier.onOpen = { [suite = models.suite] in
            suite.navigation.selection = .overview
            NSApp.activate()
        }
        models.scheduler.start()
        models.hostStatus.start()
        models.scheduledScans.start()
        return models
    }
}

// The menu bar's views are internal to the UI module; the App target gets them as opaque views.
extension AppModels {
    public var menuBarInserted: Binding<Bool> { MenuBarModel.insertedBinding(env.settings) }
    public var menuBarPopover: some View { MenuBarPopover(model: menuBar, monitor: monitor, suite: suite, hostLoad: hostLoad) }
    public var menuBarLabel: some View { MenuBarLabel(monitor: monitor) }
}
