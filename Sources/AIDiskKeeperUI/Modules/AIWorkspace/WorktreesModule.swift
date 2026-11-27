import DiskKeeperCore
import SwiftUI

enum WorktreesModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .worktrees, section: .aiWorkspace, order: 2, symbol: "arrow.triangle.branch",
                                             isEnabled: true, listCategories: [.worktree, .buildArtifact])

    @MainActor static func badge(_ ctx: ModuleContext) -> ModuleBadge? {
        ModuleBadge.reclaimable(ctx.scan.totals, categories: [.worktree, .buildArtifact])
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(ScopedItemListView(ctx: ctx, scopeName: descriptor.title,
                                   breakdown: ("worktrees", [.worktree, .buildArtifact], false)))
    }
}
