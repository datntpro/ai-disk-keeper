import DiskKeeperCore
import SwiftUI

/// Startup Items: launch agents and daemons. View-only, except a user's own agents whose program is gone.
enum StartupItemsModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .startupItems, section: .apps, order: 2, symbol: "power.circle",
                                             isEnabled: true)

    @MainActor static func model(_ ctx: ModuleContext) -> StartupItemsModel {
        let env = ctx.env.pathEnvironment
        return ctx.suite.state(.startupItems) { StartupItemsModel(inventory: live(environment: env)) }
    }

    /// The scanner behind the live app: real folders, real signatures, and the read-only load-state query (with a timeout).
    static func live(environment env: PathEnvironment) -> StartupItemsModel.Inventorying {
        {
            try await StartupItemScanner(roots: .live(env), signatures: SecStaticCodeSignatureReader(),
                                         loaded: LaunchctlLoadedState(), userID: getuid()).inventory()
        }
    }

    @MainActor static func badge(_ ctx: ModuleContext) -> ModuleBadge? {
        let count = model(ctx).items.count
        return count > 0 ? .count(count) : nil
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(StartupItemsView(model: model(ctx), coordinator: ctx.suite.cleanup))
    }

    @MainActor static func makeInspector(_ ctx: ModuleContext) -> AnyView? {
        AnyView(StartupItemsInspector(model: model(ctx)))
    }
}
