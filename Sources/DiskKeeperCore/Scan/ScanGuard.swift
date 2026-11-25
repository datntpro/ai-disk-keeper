import Foundation

/// Scan-time protected-path gate: one `ProtectedPaths` built from the built-in table plus the rules'
/// protect patterns. Immutable, Sendable. The same instance validates rule containers (via `loaderFactory`)
/// and every candidate item (via `check`).
public struct ScanGuard: Sendable {
    public let protectedPaths: ProtectedPaths

    /// `protectPatterns` must be `RuleLoadResult.protectPatterns` (already glob-escaped; not escaped again).
    public init(environment: PathEnvironment, protectPatterns: [String],
                resolver: any PathResolving = SystemPathResolver()) throws {
        protectedPaths = try ProtectedPaths(
            homeDirectory: environment.home, temporaryDirectory: environment.temporaryDirectory,
            additionalPatterns: protectPatterns, resolver: resolver)
    }

    public func check(_ path: String) -> PathVerdict { protectedPaths.check(path) }

    /// Production `RuleLoader.GuardFactory`. Builds a `ProtectedPaths` from (env.home, env.temporaryDirectory,
    /// patterns) and maps verdicts: allowed → nil; denied with a container reason → `.containerOnly`; any other
    /// denial → `.pathItself`. Throws when the guard cannot be built, so the loader fails closed.
    public static func loaderFactory(environment: PathEnvironment,
                                     resolver: any PathResolving = SystemPathResolver()) -> RuleLoader.GuardFactory {
        return { patterns in
            let guardian = try ScanGuard(environment: environment, protectPatterns: patterns, resolver: resolver)
            return { path in
                guard let denial = guardian.check(path).denial else { return nil }
                return GuardDenial(scope: denial.reason.isContainerReason ? .containerOnly : .pathItself,
                                   message: denial.message)
            }
        }
    }
}
