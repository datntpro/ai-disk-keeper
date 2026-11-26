import DiskKeeperCore
import SwiftUI

/// The shared item table for a sidebar scope, with a `StateView` instead of a blank pane when there is no data.
struct ScopedItemListView: View {
    let ctx: ModuleContext
    var scopeName: String?

    var body: some View {
        let scan = ctx.scan
        if scan.phase == .idle {
            StateView(kind: .empty, symbol: "magnifyingglass", title: loc("module.scanFirst.title", "Scan to see this data"),
                      message: loc("module.scanFirst.message", "Run a scan to see what's using space here."),
                      actions: [StateAction(title: loc("action.scan", "Scan")) { scan.startScan() }])
        } else if !scan.isScanning, ctx.list.tierCounts.values.allSatisfy({ $0 == 0 }), ctx.query.wrappedValue.searchText.isEmpty {
            StateView(kind: .empty, symbol: "checkmark.circle", title: loc("module.noItems.title", "Nothing found"),
                      message: loc("module.noItems.message", "The last scan found nothing here."))
        } else {
            ItemTableView(rows: ctx.list.rows, tierCounts: ctx.list.tierCounts, query: ctx.query,
                          inspectedID: ctx.inspectedID, selection: ctx.scanSelection, scopeName: scopeName)
        }
    }
}
