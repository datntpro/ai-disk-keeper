import DiskKeeperCore
import Foundation

/// Composition root. Tests build their own; they never call `live()`, so no test touches the real home.
/// T10 and T11 each add one stored property and one line to `live()`.
@MainActor
public final class AppEnvironment {
    public let pathEnvironment: PathEnvironment
    /// Called OFF the main actor (it loads rule JSON from disk). One new engine per scan.
    public var makeScanEngine: @Sendable () throws -> any ScanEngineProtocol
    /// T11: user settings (scan scope, onboarding, Full Disk Access status).
    public let settings: SettingsModel

    /// T10: the one `CleanupEngine` per app (or why it is unavailable). Never falls back to an unguarded engine.
    public let cleanup: CleanupEngineHolder

    /// T42: builds the one disk indexer for a map run. Called OFF the main actor (it loads rule JSON).
    public var makeDiskIndexer: @Sendable () throws -> any DiskIndexing

    public init(pathEnvironment: PathEnvironment,
                settings: SettingsModel? = nil,
                makeScanEngine: @escaping @Sendable () throws -> any ScanEngineProtocol,
                cleanup: CleanupEngineHolder = CleanupEngineHolder(),
                makeDiskIndexer: @escaping @Sendable () throws -> any DiskIndexing = { throw DiskIndexUnavailable() }) {
        self.pathEnvironment = pathEnvironment
        self.makeScanEngine = makeScanEngine
        self.settings = settings ?? SettingsModel(
            store: SettingsStore(environment: pathEnvironment), environment: pathEnvironment, probe: { .unknown })
        self.cleanup = cleanup
        self.makeDiskIndexer = makeDiskIndexer
    }

    public static func live() -> AppEnvironment {
        let env = PathEnvironment.current()
        let probe = FullDiskAccessProbe.standard(environment: env)
        let settings = SettingsModel(store: SettingsStore(environment: env), environment: env,
                                     probe: { probe.check() })
        L10n.apply(settings.language)   // before the first scene builds
        #if DEBUG
        if CommandLine.arguments.contains("--pseudo-localize") { L10n.applyPseudo() }
        #endif
        // The tool list comes from the loaded rules; loading reads disk, so keep it off the main actor.
        Task.detached {
            let loaded = RuleLoader(
                environment: env, bundledRulesDirectory: CoreResources.rulesDirectoryURL, userRulesDirectory: nil,
                guardFactory: ScanGuard.loaderFactory(environment: env)).load()
            var seen = Set<ToolID>()
            let tools = loaded.ruleSets.map(\.tool).filter { seen.insert($0.id).inserted }
                .map { ToolChoice(id: $0.id, name: $0.name) }
            RuleTexts.install(RuleTextIndex(rules: loaded.allRules))
            await MainActor.run { settings.availableTools = tools }
        }
        let cleanup = CleanupEngineHolder()
        // Rule loading reads disk: build the one cleanup engine off the main actor.
        Task.detached {
            let result = Result { try CleanupEngine.makeDefault(
                environment: env, runningApps: WorkspaceRunningApps(), toolCommands: ToolCommandPerformer.live(environment: env)) }
            await MainActor.run {
                switch result {
                case .success(let engine): cleanup.install(engine)
                case .failure(let error): cleanup.fail(String(describing: error))
                }
            }
        }
        let provider = settings.scopeProvider   // current scope is read when each scan starts
        return AppEnvironment(pathEnvironment: env, settings: settings, makeScanEngine: {
            try ScanEngine.makeDefault(environment: env, userRulesDirectory: nil,
                                       extraScanners: BuiltInScanners.live(environment: env), scope: provider.current)
        }, cleanup: cleanup, makeDiskIndexer: {
            let loaded = RuleLoader(
                environment: env, bundledRulesDirectory: CoreResources.rulesDirectoryURL, userRulesDirectory: nil,
                guardFactory: ScanGuard.loaderFactory(environment: env)).load()
            let pathGuard = try ScanGuard(environment: env, protectPatterns: loaded.protectPatterns).protectedPaths
            return DiskIndexer(environment: env, pathGuard: pathGuard)
        })
    }
}
