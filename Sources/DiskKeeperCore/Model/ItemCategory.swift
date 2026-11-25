import Foundation

/// Broad kind of a scan item. Raw values equal the case names (used by rule JSON).
public enum ItemCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case aiToolData, worktree, buildArtifact, modelWeights, systemJunk, docker

    /// English display name.
    public var displayName: String {
        switch self {
        case .aiToolData: "AI tool data"
        case .worktree: "Worktrees"
        case .buildArtifact: "Build artifacts"
        case .modelWeights: "Model weights"
        case .systemJunk: "System junk"
        case .docker: "Docker"
        }
    }
}
