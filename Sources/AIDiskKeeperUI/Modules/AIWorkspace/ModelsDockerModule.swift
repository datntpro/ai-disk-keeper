import DiskKeeperCore
import SwiftUI

enum ModelsDockerModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .modelsDocker, section: .aiWorkspace, order: 3, symbol: "cube.transparent",
                                             isEnabled: true, listCategories: [.modelWeights, .docker])

    @MainActor static func badge(_ ctx: ModuleContext) -> ModuleBadge? {
        ModuleBadge.reclaimable(ctx.scan.totals, categories: [.modelWeights, .docker])
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(ScopedItemListView(ctx: ctx, scopeName: descriptor.title))
    }
}
