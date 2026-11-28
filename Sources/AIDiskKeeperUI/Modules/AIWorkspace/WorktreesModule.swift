import DiskKeeperCore
import SwiftUI

enum WorktreesModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .worktrees, section: .aiWorkspace, order: 2, symbol: "arrow.triangle.branch",
                                             isEnabled: true, listCategories: [.worktree, .buildArtifact])

    @MainActor static func badge(_ ctx: ModuleContext) -> ModuleBadge? {
        ModuleBadge.reclaimable(ctx.scan.totals, categories: [.worktree, .buildArtifact])
    }

    @MainActor static func manager(_ ctx: ModuleContext) -> WorktreeManagerModel {
        ctx.suite.state(.worktrees) {
            let settings = ctx.env.settings
            let consent = GitHubConsentModel(
                isOn: { settings.settings.useGitHubCLIForPRs }, store: .defaults(),
                apply: { settings.setUseGitHubCLIForPRs($0) })
            return WorktreeManagerModel(settings: { settings.settings }, consent: consent, makeInventory: ctx.env.makeWorktreeInventory)
        }
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(WorktreesDetailView(ctx: ctx, model: manager(ctx)))
    }
}

/// Inventory (read-only manager) and the existing build-artifact list with its breakdown header.
struct WorktreesDetailView: View {
    let ctx: ModuleContext
    let model: WorktreeManagerModel
    @State private var tab: Tab = .inventory
    enum Tab { case inventory, artifacts }

    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $tab) {
                Text(WorktreeCopy.tabInventory).tag(Tab.inventory)
                Text(WorktreeCopy.tabArtifacts).tag(Tab.artifacts)
            } label: { EmptyView() }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, ADKTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            switch tab {
            case .inventory: WorktreeManagerView(model: model)
            case .artifacts:
                ScopedItemListView(ctx: ctx, scopeName: WorktreesModule.descriptor.title,
                                   breakdown: ("worktrees", [.worktree, .buildArtifact], false))
            }
        }
    }
}
