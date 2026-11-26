import Foundation

/// Broad kind of a scan item. Raw values equal the case names (used by rule JSON).
public enum ItemCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case aiToolData, worktree, buildArtifact, modelWeights, systemJunk, docker
    // M4 (append only; order is the raw-value list tests pin)
    case largeFile, duplicate, application, appLeftover, startupItem

    /// Categories a JSON rule may use. The M4 categories are produced by built-in Swift scanners only.
    public static let ruleCategories: Set<ItemCategory> = [
        .aiToolData, .worktree, .buildArtifact, .modelWeights, .systemJunk, .docker,
    ]

    public var isRuleCategory: Bool { Self.ruleCategories.contains(self) }

    /// Personal data / per-item decisions: never bulk-selectable ("Select all Safe" never picks them).
    public var isNeverBulkSelectable: Bool {
        switch self {
        case .modelWeights, .largeFile, .duplicate, .application, .appLeftover, .startupItem: true
        case .aiToolData, .worktree, .buildArtifact, .systemJunk, .docker: false
        }
    }

    /// English display name.
    public var displayName: String {
        switch self {
        case .aiToolData: "AI tool data"
        case .worktree: "Worktrees"
        case .buildArtifact: "Build artifacts"
        case .modelWeights: "Model weights"
        case .systemJunk: "System junk"
        case .docker: "Docker"
        case .largeFile: "Large files"
        case .duplicate: "Duplicates"
        case .application: "Applications"
        case .appLeftover: "App leftovers"
        case .startupItem: "Startup items"
        }
    }
}
