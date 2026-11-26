import AppKit
import DiskKeeperCore
import SwiftUI

/// One band of the strata bar and the disk map. Colour is never the only signal: every layer also has a title.
enum StrataLayer: CaseIterable, Sendable, Hashable {
    case ai, worktree, build, model, docker, junk, apps, media, other

    init(category: ItemCategory?) {
        guard let category else { self = .other; return }
        switch category {
        case .aiToolData: self = .ai
        case .worktree: self = .worktree
        case .buildArtifact: self = .build
        case .modelWeights: self = .model
        case .docker: self = .docker
        case .systemJunk: self = .junk
        case .application, .appLeftover, .startupItem: self = .apps
        case .largeFile, .duplicate: self = .media
        }
    }

    func rgba(_ appearance: ADKAppearance) -> RGBA { StrataPalette.layer(self, appearance) }

    var nsColor: NSColor {
        let layer = self
        return NSColor(name: nil) { layer.rgba(ADKAppearance($0)).nsColor }
    }

    var color: Color { Color(nsColor: nsColor) }

    var title: String {
        switch self {
        case .ai: loc("strata.layer.ai", "AI tool data")
        case .worktree: loc("strata.layer.worktree", "Worktrees")
        case .build: loc("strata.layer.build", "Build artifacts")
        case .model: loc("strata.layer.model", "Models")
        case .docker: loc("strata.layer.docker", "Docker")
        case .junk: loc("strata.layer.junk", "Caches & logs")
        case .apps: loc("strata.layer.apps", "Apps")
        case .media: loc("strata.layer.media", "Documents & media")
        case .other: loc("strata.layer.other", "Other")
        }
    }
}
