import Observation

/// Holds the single app-wide cleanup engine once it has been built off the main actor.
@MainActor @Observable
public final class CleanupEngineHolder {
    public private(set) var engine: (any CleanupEngineProtocol)?
    public private(set) var error: String?
    public init(engine: (any CleanupEngineProtocol)? = nil, error: String? = nil) {
        self.engine = engine
        self.error = error
    }

    /// The one place the app-wide engine is set. There is exactly one `CleanupEngine` per app (its run lock and
    /// plan registry are per instance), so a second install is a programming error.
    public func install(_ engine: any CleanupEngineProtocol) {
        precondition(self.engine == nil, "CleanupEngineHolder: one CleanupEngine per app")
        self.engine = engine; error = nil
    }
    public func fail(_ message: String) { error = message }
}
