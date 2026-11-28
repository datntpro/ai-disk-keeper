import Foundation

extension CleanupEngine {
    /// Same protected set as scanning: built-in table + bundled rules' protect patterns. Audit log at
    /// `AuditLog.defaultURL(environment:)`. Throws if the guard can't be built (never runs without one).
    /// Permanent delete is not exposed: `options` keeps its defaults.
    public static func makeDefault(environment: PathEnvironment,
                                   bundledRulesDirectory: URL? = CoreResources.rulesDirectoryURL,
                                   runningApps: any RunningAppChecking,
                                   toolCommands: ToolCommandPerformer? = nil,
                                   inUse: (any ProcessUsageSource)? = nil) throws -> CleanupEngine {
        let loaded = RuleLoader(
            environment: environment, bundledRulesDirectory: bundledRulesDirectory,
            guardFactory: ScanGuard.loaderFactory(environment: environment)).load()
        let pathGuard = try ScanGuard(environment: environment, protectPatterns: loaded.protectPatterns)
        return CleanupEngine(pathGuard: pathGuard.protectedPaths,
                             auditLog: AuditLog(fileURL: AuditLog.defaultURL(environment: environment)),
                             runningApps: runningApps,
                             appPolicy: ApplicationBundlePolicy(roots: .live(environment), userID: getuid(),
                                                                probe: LiveAppBundleProbe()),
                             toolCommands: toolCommands, inUse: inUse ?? LibprocUsageSource())
    }
}
