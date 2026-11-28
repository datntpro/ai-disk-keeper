import CryptoKit
import Darwin
import DiskKeeperCore
import Foundation

/// The live Care Scan: the real stages around the real scanners, built per scan (cheap) and off the main actor
/// (building the guard loads rule JSON). Every stage is read-only.
struct CareScanLive: Sendable {
    let environment: PathEnvironment
    /// The same factory ⌘R used before the Care Scan (the user's scan scope included).
    let makeScanEngine: @Sendable () throws -> any ScanEngineProtocol
    let scopeProvider: ScopeProvider
    let index: DiskIndexModel

    struct Unavailable: Error, CustomStringConvertible { var description: String { "scan engine unavailable" } }

    func makeCoordinator(indexScope: DiskIndexer.Scope) throws -> CareScanCoordinator {
        let env = environment
        let pathGuard = try Self.loadGuard(env)
        let context = ScanContext(environment: env, pathGuard: pathGuard)
        let makeEngine = makeScanEngine
        let index = index
        let roots = AppRoots.live(env)
        let stages: [CareStageSpec] = [
            CareStages.rules {
                guard let engine = try makeEngine() as? ScanEngine else { throw Unavailable() }
                return engine
            },
            CareStages.index { try await index.build(indexScope) },
            CareStages.largeOld(
                LargeFileScanner(options: LargeFileOptions(environment: env), lastOpened: SpotlightLastOpenedProvider(),
                                 appNames: ApplicationsFolderNames.live(env), tree: { throw CancellationError() }),
                context: context),
            CareStages.duplicates(options: DuplicateOptions(environment: env), keeper: .oldest,
                                  guardProvider: { pathGuard }, userID: getuid()),
            CareStages.apps(
                inventory: {
                    try await AppInventoryScanner(roots: roots, signatures: SecStaticCodeSignatureReader(),
                                                  usage: SpotlightUsageProvider(), runningApps: WorkspaceRunningApps()).inventory()
                },
                leftovers: { inventory in
                    ScanEngine(context: context, scanners: [
                        AppLeftoverScanner(inventory: { inventory }, library: roots.library, lookup: LaunchServicesBundleLookup()),
                    ], adjusters: [InUseAdjuster(source: LibprocUsageSource())])
                }),
            CareStages.scannerRun(.startup, modules: [.startup]) {
                ScanEngine(context: context, scanners: [
                    StartupItemScanner(roots: .live(env), signatures: SecStaticCodeSignatureReader(),
                                       loaded: LaunchctlLoadedState(), userID: getuid()),
                ])
            },
        ]
        return CareScanCoordinator(stages: stages, history: CareHistoryStore(fileURL: CareHistoryStore.defaultFileURL(environment: env)),
                                   scopeFingerprint: Self.fingerprint(scope: scopeProvider.current, index: indexScope))
    }

    private static func loadGuard(_ env: PathEnvironment) throws -> ScanGuard {
        let loaded = RuleLoader(environment: env, bundledRulesDirectory: CoreResources.rulesDirectoryURL,
                                userRulesDirectory: nil, guardFactory: ScanGuard.loaderFactory(environment: env)).load()
        return try ScanGuard(environment: env, protectPatterns: loaded.protectPatterns)
    }

    /// SHA-256 of what changes the numbers' meaning: disabled tools, project roots, excluded paths and the index scope.
    /// Growth only compares scans with the same fingerprint.
    static func fingerprint(scope: ScanScope, index: DiskIndexer.Scope) -> String {
        let indexName: String = switch index {
        case .home: "home"
        case .fullDisk: "fullDisk"
        case .folder(let path): "folder:" + path
        }
        let parts = ["tools:" + scope.disabledTools.map(\.rawValue).sorted().joined(separator: ","),
                     "roots:" + scope.projectRoots.sorted().joined(separator: ","),
                     "excluded:" + scope.excludedPaths.sorted().joined(separator: ","),
                     "index:" + indexName]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
