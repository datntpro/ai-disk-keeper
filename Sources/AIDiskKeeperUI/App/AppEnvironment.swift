import DiskKeeperCore
import Foundation

/// Composition root. Tests build their own; they never call `live()`, so no test touches the real home.
/// T10 and T11 each add one stored property and one line to `live()`.
@MainActor
public final class AppEnvironment {
    public let pathEnvironment: PathEnvironment
    /// Called OFF the main actor (it loads rule JSON from disk). One new engine per scan.
    public var makeScanEngine: @Sendable () throws -> any ScanEngineProtocol

    public init(pathEnvironment: PathEnvironment,
                makeScanEngine: @escaping @Sendable () throws -> any ScanEngineProtocol) {
        self.pathEnvironment = pathEnvironment
        self.makeScanEngine = makeScanEngine
    }

    public static func live() -> AppEnvironment {
        let env = PathEnvironment.current()
        return AppEnvironment(pathEnvironment: env) {
            try ScanEngine.makeDefault(environment: env, userRulesDirectory: nil)
        }
    }
}
