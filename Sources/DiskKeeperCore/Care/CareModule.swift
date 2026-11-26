import Foundation

/// What the Overview tiles show. Mapped from ``ItemCategory``, so a new scanner lands in a module automatically.
public enum CareModule: String, Sendable, Codable, CaseIterable {
    case aiTools, worktrees, modelsDocker, systemJunk, largeOld, duplicates, apps, startup

    public init(category: ItemCategory) {
        switch category {
        case .aiToolData: self = .aiTools
        case .worktree, .buildArtifact: self = .worktrees
        case .modelWeights, .docker: self = .modelsDocker
        case .systemJunk: self = .systemJunk
        case .largeFile: self = .largeOld
        case .duplicate: self = .duplicates
        case .application, .appLeftover: self = .apps
        case .startupItem: self = .startup
        }
    }
}
