import SwiftUI

/// Large & Old Files: big files you haven't opened for a while, from the shared disk index. Always Review.
enum LargeOldModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .largeOld, section: .storage, order: 2, symbol: "doc.badge.clock",
                                             isEnabled: true)

    @MainActor static func model(_ ctx: ModuleContext) -> LargeOldModel {
        ctx.suite.state(.largeOld) {
            LargeOldModel(index: ctx.suite.diskIndex, scanner: LargeOldModel.live(environment: ctx.env.pathEnvironment))
        }
    }

    @MainActor static func badge(_ ctx: ModuleContext) -> ModuleBadge? {
        let model = model(ctx)
        guard model.report != nil else { return nil }
        let bytes = model.badgeBytes
        return bytes > 0 ? .bytes(bytes) : nil
    }

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(LargeOldView(model: model(ctx), coordinator: ctx.suite.cleanup))
    }

    @MainActor static func makeInspector(_ ctx: ModuleContext) -> AnyView? {
        AnyView(LargeOldInspector(model: model(ctx)))
    }
}
