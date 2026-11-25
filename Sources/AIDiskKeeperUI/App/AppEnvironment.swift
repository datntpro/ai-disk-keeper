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

    public init(pathEnvironment: PathEnvironment,
                settings: SettingsModel? = nil,
                makeScanEngine: @escaping @Sendable () throws -> any ScanEngineProtocol) {
        self.pathEnvironment = pathEnvironment
        self.makeScanEngine = makeScanEngine
        self.settings = settings ?? SettingsModel(
            store: SettingsStore(environment: pathEnvironment), environment: pathEnvironment, probe: { .unknown })
    }

    public static func live() -> AppEnvironment {
        let env = PathEnvironment.current()
        let probe = FullDiskAccessProbe.standard(environment: env)
        let settings = SettingsModel(store: SettingsStore(environment: env), environment: env,
                                     probe: { probe.check() })
        // The tool list comes from the loaded rules; loading reads disk, so keep it off the main actor.
        Task.detached {
            let loaded = RuleLoader(
                environment: env, bundledRulesDirectory: CoreResources.rulesDirectoryURL, userRulesDirectory: nil,
                guardFactory: ScanGuard.loaderFactory(environment: env)).load()
            var seen = Set<ToolID>()
            let tools = loaded.ruleSets.map(\.tool).filter { seen.insert($0.id).inserted }
                .map { ToolChoice(id: $0.id, name: $0.name) }
            await MainActor.run { settings.availableTools = tools }
        }
        let provider = settings.scopeProvider   // current scope is read when each scan starts
        return AppEnvironment(pathEnvironment: env, settings: settings) {
            try ScanEngine.makeDefault(environment: env, userRulesDirectory: nil, scope: provider.current)
        }
    }
}
