import DiskKeeperCore
import SwiftUI

/// Duplicates: identical files in Home, keep-one enforced by the UI and by the cleanup engine.
enum DuplicatesModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .duplicates, section: .storage, order: 3, symbol: "doc.on.doc",
                                             isEnabled: true)

    /// The one model for this module (kept by the suite, so it survives switching modules).
    @MainActor static func model(_ ctx: ModuleContext) -> DuplicatesModel { model(env: ctx.env, suite: ctx.suite) }

    /// Same instance without a `ModuleContext` (the Care Scan adopts its report into it).
    @MainActor static func model(env appEnv: AppEnvironment, suite: SuiteModel) -> DuplicatesModel {
        let env = appEnv.pathEnvironment
        return suite.state(.duplicates) {
            DuplicatesModel(index: suite.diskIndex, finder: DuplicatesModel.liveFinder, environment: env,
                            guardProvider: { try Self.liveGuard(env) })
        }
    }

    /// Loading rule JSON reads disk; the model calls this off the main actor.
    private static func liveGuard(_ env: PathEnvironment) throws -> ScanGuard {
        let loaded = RuleLoader(environment: env, bundledRulesDirectory: CoreResources.rulesDirectoryURL,
                                userRulesDirectory: nil, guardFactory: ScanGuard.loaderFactory(environment: env)).load()
        return try ScanGuard(environment: env, protectPatterns: loaded.protectPatterns)
    }

    @MainActor static func badge(_ ctx: ModuleContext) -> ModuleBadge? {
        let bytes = model(ctx).totalSavings
        return bytes > 0 ? .bytes(bytes) : nil
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(DuplicatesView(model: model(ctx), index: ctx.suite.diskIndex, cleanup: ctx.suite.cleanup))
    }

    @MainActor static func makeInspector(_ ctx: ModuleContext) -> AnyView? {
        AnyView(DuplicatesInspector(model: model(ctx)))
    }
}
