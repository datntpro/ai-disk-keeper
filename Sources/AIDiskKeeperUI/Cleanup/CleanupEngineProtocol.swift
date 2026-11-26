import DiskKeeperCore

/// The seam between the UI and the cleanup engine, so the flow model can be tested with a fake.
public protocol CleanupEngineProtocol: Sendable {
    func plan(_ items: [ScanItem]) async -> CleanupPlan
    func execute(_ plan: CleanupPlan, progress: (@Sendable (CleanupProgress) -> Void)?) async throws -> CleanupReport
}

extension CleanupEngine: CleanupEngineProtocol {}
