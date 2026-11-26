import Foundation

/// Execution stages of a Care Scan, in the fixed order of `allCases`. A stage covers one or more modules.
public enum CareStage: String, Sendable, Codable, CaseIterable {
    /// RuleScanner + any extra ScanEngine scanners (worktrees, models, Docker): aiTools, worktrees, modelsDocker, systemJunk.
    case rules
    /// DiskIndexer → DiskTree (shared by `largeOld` and `duplicates`).
    case index
    case largeOld, duplicates, apps, startup
}

/// Results a module screen can adopt so the work isn't done twice.
public enum CareArtifact: Sendable {
    case tree(DiskTree), largeFiles(LargeFileReport), duplicates(DuplicateReport), apps(AppInventory)
}

public struct CareStageInput: Sendable {
    /// The tree the `index` stage produced; nil when no index stage ran or it failed.
    public let tree: DiskTree?
    public let now: Date
    public init(tree: DiskTree?, now: Date) {
        self.tree = tree
        self.now = now
    }
}

/// Callbacks into the coordinator, all called from the stage's own task.
public struct CareStageSink: Sendable {
    public let item: @Sendable (ScanItem) async -> Void
    public let warning: @Sendable (ScanWarning) async -> Void
    /// 0…1, or nil for indeterminate.
    public let progress: @Sendable (Double?) async -> Void
    /// Raw events of ScanEngine-based stages.
    public let scanEvent: @Sendable (ScanEvent) async -> Void
    public let artifact: @Sendable (CareArtifact) async -> Void

    public init(item: @escaping @Sendable (ScanItem) async -> Void,
                warning: @escaping @Sendable (ScanWarning) async -> Void,
                progress: @escaping @Sendable (Double?) async -> Void,
                scanEvent: @escaping @Sendable (ScanEvent) async -> Void,
                artifact: @escaping @Sendable (CareArtifact) async -> Void) {
        self.item = item
        self.warning = warning
        self.progress = progress
        self.scanEvent = scanEvent
        self.artifact = artifact
    }
}

public struct CareStageSpec: Sendable {
    public let stage: CareStage
    /// Chips lit when this stage finishes.
    public let modules: [CareModule]
    /// The stage needs the `index` stage's tree; it is skipped when there is none.
    public let needsTree: Bool
    public let run: @Sendable (CareStageInput, CareStageSink) async throws -> Void

    public init(stage: CareStage, modules: [CareModule], needsTree: Bool = false,
                run: @escaping @Sendable (CareStageInput, CareStageSink) async throws -> Void) {
        self.stage = stage
        self.modules = modules
        self.needsTree = needsTree
        self.run = run
    }
}
