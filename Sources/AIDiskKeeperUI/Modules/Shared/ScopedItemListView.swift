import DiskKeeperCore
import SwiftUI

/// The shared item table for a sidebar scope, with a `StateView` instead of a blank pane when there is no data.
struct ScopedItemListView: View {
    let ctx: ModuleContext
    var scopeName: String?
    /// Optional breakdown charts above the table: (module key, categories, show the "By tool" chart).
    var breakdown: (key: String, categories: Set<ItemCategory>, showTool: Bool)?

    var body: some View {
        let scan = ctx.scan
        let query = ctx.query.wrappedValue.searchText
        let state = ModuleStateResolver.state(
            hasRun: scan.phase != .idle, isLoading: false, progress: nil, itemCount: ctx.list.scopeCount,
            filteredCount: ctx.list.rows.count, query: query, warnings: scan.warnings, error: nil)
        if state == .firstRun {
            StateView(kind: .firstRun, symbol: "magnifyingglass", title: StateCopy.notScanned,
                      message: loc("module.scanFirst.message", "Run a scan to see what's using space here."),
                      actions: [StateAction(title: loc("action.scan", "Scan")) { scan.startScan() }])
        } else if !scan.isScanning, state == .empty {
            StateView(kind: .empty, symbol: "checkmark.circle", title: scopeName.map(StateCopy.emptyModule) ?? StateCopy.emptyNothing,
                      message: loc("module.noItems.message", "The last scan found nothing here."))
        } else if !scan.isScanning, ctx.list.rows.isEmpty, ctx.list.scopeCount > 0,
                  ctx.query.wrappedValue.tiers != Set(RiskTier.allCases) {
            StateView(kind: .filteredEmpty, symbol: "line.3.horizontal.decrease.circle", title: StateCopy.filteredTiersTitle,
                      message: StateCopy.filteredTiersBody,
                      actions: [StateAction(title: StateCopy.filteredShowAll) { ctx.query.wrappedValue.tiers = Set(RiskTier.allCases) }])
        } else {
            VStack(spacing: 0) {
                if let count = ModuleStateResolver.fdaBanner(warnings: scan.warnings, fdaGranted: false) {
                    FDABanner(count: count).padding([.horizontal, .top], ADKTheme.Spacing.lg)
                }
                if let breakdown {
                    BreakdownHeader(ctx: ctx, moduleKey: breakdown.key, categories: breakdown.categories, showTool: breakdown.showTool)
                        .id(breakdown.key)
                }
                let reclaim = ReclaimEstimate.make(items: ctx.list.rows.filter(\.isSelectable))
                if reclaim.isMuchSmaller, let line = ReclaimCopy.line(for: reclaim) {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, ADKTheme.Spacing.lg).padding(.vertical, 4)
                }
                ItemTableView(rows: ctx.list.rows, tierCounts: ctx.list.tierCounts, query: ctx.query,
                              inspectedID: ctx.inspectedID, selection: ctx.scanSelection, scopeName: scopeName,
                              filteredEmpty: Self.filteredEmpty(state, scanning: scan.isScanning))
            }
        }
    }

    /// The filtered-empty overlay for a resolved state; nil while scanning or for any other state.
    static func filteredEmpty(_ state: ModuleState, scanning: Bool) -> FilteredEmpty? {
        guard !scanning, case .filteredEmpty(let q) = state else { return nil }
        return FilteredEmpty(title: StateCopy.filteredTitle(q))
    }
}
