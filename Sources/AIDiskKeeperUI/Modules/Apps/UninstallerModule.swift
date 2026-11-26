import AppKit
import DiskKeeperCore
import SwiftUI

/// Uninstaller: apps, the files they keep in your Library, and leftovers of apps that are gone.
enum UninstallerModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .uninstaller, section: .apps, order: 1, symbol: "xmark.app",
                                             isEnabled: true)

    @MainActor static func model(_ ctx: ModuleContext) -> UninstallerModel {
        let env = ctx.env.pathEnvironment
        return ctx.suite.state(.uninstaller) {
            UninstallerModel(inventory: liveInventory(env), leftovers: liveLeftovers(env),
                             runningApps: liveRunning, home: env.home)
        }
    }

    /// Bundle ids of the apps running right now.
    @MainActor static func liveRunning() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier))
    }

    /// Real folders, real signatures, Spotlight last-used dates. Read-only.
    static func liveInventory(_ env: PathEnvironment) -> UninstallerModel.Inventorying {
        {
            try await AppInventoryScanner(roots: .live(env), signatures: SecStaticCodeSignatureReader(),
                                          usage: SpotlightUsageProvider(), runningApps: WorkspaceRunningApps()).inventory()
        }
    }

    /// One `ScanEngine` run of the leftover scanner over `~/Library`. The guard is built off the main actor.
    static func liveLeftovers(_ env: PathEnvironment) -> UninstallerModel.Leftovers {
        { inventory in
            let loaded = RuleLoader(environment: env, bundledRulesDirectory: CoreResources.rulesDirectoryURL,
                                    userRulesDirectory: nil, guardFactory: ScanGuard.loaderFactory(environment: env)).load()
            let pathGuard = try ScanGuard(environment: env, protectPatterns: loaded.protectPatterns)
            let context = ScanContext(environment: env, pathGuard: pathGuard, now: Date())
            let scanner = AppLeftoverScanner(inventory: { inventory }, library: env.home + "/Library",
                                             lookup: LaunchServicesBundleLookup())
            let engine = ScanEngine(context: context, scanners: [scanner])
            for await event in try await engine.scan() {
                switch event {
                case .finished(let result), .cancelled(let result): return result
                default: continue
                }
            }
            throw CancellationError()
        }
    }

    @MainActor static func badge(_ ctx: ModuleContext) -> ModuleBadge? {
        let count = model(ctx).apps.count
        return count > 0 ? .count(count) : nil
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(UninstallerView(model: model(ctx), coordinator: ctx.suite.cleanup))
    }
}
