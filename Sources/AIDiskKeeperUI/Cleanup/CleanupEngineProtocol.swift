import DiskKeeperCore

/// The seam between the UI and the cleanup engine, so the flow model can be tested with a fake.
public protocol CleanupEngineProtocol: Sendable {
    func plan(_ items: [ScanItem]) async -> CleanupPlan
    /// A requirement without a default, so a fake can't silently drop the groups the keep-one check needs.
    func plan(_ items: [ScanItem], duplicateGroups: [String: DuplicateGroup]) async -> CleanupPlan
    func execute(_ plan: CleanupPlan, progress: (@Sendable (CleanupProgress) -> Void)?) async throws -> CleanupReport
}

extension CleanupEngine: CleanupEngineProtocol {}
