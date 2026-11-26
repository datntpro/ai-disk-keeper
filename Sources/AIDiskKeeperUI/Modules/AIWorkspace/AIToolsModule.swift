import DiskKeeperCore
import SwiftUI

enum AIToolsModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .aiTools, section: .aiWorkspace, order: 1, symbol: "cpu",
                                             isEnabled: true, listCategories: [.aiToolData])

    @MainActor static func badge(_ ctx: ModuleContext) -> ModuleBadge? {
        ModuleBadge.reclaimable(ctx.scan.totals, categories: [.aiToolData])
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(ScopedItemListView(ctx: ctx, scopeName: descriptor.title))
    }
}
