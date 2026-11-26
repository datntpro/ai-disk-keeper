import DiskKeeperCore
import SwiftUI

/// The shared item table for a sidebar scope, with a `StateView` instead of a blank pane when there is no data.
struct ScopedItemListView: View {
    let ctx: ModuleContext
    var scopeName: String?

    var body: some View {
        let scan = ctx.scan
        let query = ctx.query.wrappedValue.searchText
        let hasData = ctx.list.tierCounts.values.contains { $0 > 0 }
        if scan.phase == .idle {
            StateView(kind: .firstRun, symbol: "magnifyingglass", title: StateCopy.notScanned,
                      message: loc("module.scanFirst.message", "Run a scan to see what's using space here."),
                      actions: [StateAction(title: loc("action.scan", "Scan")) { scan.startScan() }])
        } else if !scan.isScanning, !hasData, query.isEmpty {
            StateView(kind: .empty, symbol: "checkmark.circle", title: StateCopy.emptyModule(scopeName ?? loc("module.generic", "this")),
                      message: loc("module.noItems.message", "The last scan found nothing here."))
        } else {
            VStack(spacing: 0) {
                if let count = ModuleStateResolver.fdaBanner(warnings: scan.warnings, fdaGranted: false) {
                    FDABanner(count: count).padding([.horizontal, .top], ADKTheme.Spacing.lg)
                }
                if !query.isEmpty, hasData, ctx.list.rows.isEmpty, !scan.isScanning {
                    StateView(kind: .filteredEmpty, symbol: "magnifyingglass", title: StateCopy.filteredTitle(query),
                              message: StateCopy.filteredBody,
                              actions: [StateAction(title: StateCopy.filteredClear) { ctx.query.wrappedValue.searchText = "" }])
                } else {
                    ItemTableView(rows: ctx.list.rows, tierCounts: ctx.list.tierCounts, query: ctx.query,
                                  inspectedID: ctx.inspectedID, selection: ctx.scanSelection, scopeName: scopeName)
                }
            }
        }
    }
}
