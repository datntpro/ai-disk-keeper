import DiskKeeperCore
import SwiftUI

enum DiskMapModule: ModuleProvider {
    static let descriptor = ModuleDescriptor(id: .diskMap, section: .storage, order: 1, symbol: "square.stack.3d.down.right",
                                             isEnabled: true)

    @MainActor static func makeDetail(_ ctx: ModuleContext) -> AnyView {
        AnyView(DiskMapView(model: model(ctx), ctx: ctx))
    }

    @MainActor static func makeInspector(_ ctx: ModuleContext) -> AnyView? {
        let model = model(ctx)
        return AnyView(DiskMapInspectorView(model: model) { review($0, ctx) })
    }

    /// The one model behind both the detail and the inspector, kept in the suite so it survives module switches.
    @MainActor static func model(_ ctx: ModuleContext) -> DiskMapModel {
        let scan = ctx.scan
        return ctx.suite.state(.diskMap) {
            DiskMapModel(index: ctx.suite.diskIndex, scanItems: { scan.items })
        }
    }

    /// "Review in list": jumps to the list module and inspects the item. Navigation only; nothing is selected.
    @MainActor static func review(_ id: ScanItem.ID, _ ctx: ModuleContext) {
        guard let item = ctx.scan.item(id: id) else { return }
        var query = ctx.query.wrappedValue
        var inspected = ctx.inspectedID.wrappedValue
        ctx.suite.navigation.show(item: item, query: &query, inspectedID: &inspected)
        ctx.query.wrappedValue = query
        ctx.inspectedID.wrappedValue = inspected
    }
}
