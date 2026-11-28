import DiskKeeperCore
import SwiftUI

/// Overview is the Care Scan (decision 1: the sidebar's Care Scan entry stays hidden).
enum OverviewModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .overview, section: .top, order: 1,
                                             symbol: "gauge.with.dots.needle.33percent", isEnabled: true)

    /// The one Care Scan model of the window, kept by the suite. Takes no `ModuleContext`, so the menu bar (T47) can
    /// get the SAME instance.
    @MainActor static func careModel(env: AppEnvironment, scan: ScanViewModel, suite: SuiteModel) -> CareScanModel {
        suite.state(.overview) {
            let live = CareScanLive(environment: env.pathEnvironment, makeScanEngine: env.makeScanEngine,
                                    scopeProvider: env.settings.scopeProvider,
                                    userPolicy: env.settings.userPolicyProvider, index: suite.diskIndex)
            return CareScanModel(
                makeCoordinator: { try live.makeCoordinator(indexScope: $0) },
                scan: scan, index: suite.diskIndex,
                duplicates: { DuplicatesModule.model(env: env, suite: suite) },
                largeOld: { LargeOldModule.model(env: env, suite: suite) })
        }
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        let care = careModel(env: ctx.env, scan: ctx.scan, suite: ctx.suite)
        return AnyView(
            OverviewView(care: care, scan: ctx.scan, storage: StorageModule.model(ctx), cleanup: ctx.suite.cleanup,
                         selection: ctx.scanSelection,
                         open: { ctx.suite.navigation.selection = $0 },
                         inspect: { item in
                             ctx.suite.navigation.selection = BiggestWins.destination(for: [item]) ?? .overview
                             ctx.inspectedID.wrappedValue = item.id
                         },
                         showWarnings: { ctx.suite.navigation.selection = .warnings }))
    }
}
