import DiskKeeperCore
import Foundation
import Observation

/// Computes the filtered, sorted table rows off the main thread and publishes them when ready, so a large scan
/// never blocks the UI on a sort. A newer request cancels the one in flight.
@MainActor @Observable
final class ItemListModel {
    private(set) var rows: [ScanItem] = []
    /// Per-tier counts within the sidebar scope + search (ignores the tier filter), for the chips.
    private(set) var tierCounts: [RiskTier: Int] = [:]

    /// Items in the sidebar scope before search and tier filters: tells "nothing here" from "nothing matches".
    private(set) var scopeCount = 0

    @ObservationIgnored private var task: Task<Void, Never>?

    func update(items: [ScanItem], query: ItemQuery) {
        task?.cancel()
        task = Task { [weak self] in
            let (rows, counts, total) = await Task.detached(priority: .userInitiated) { () -> ([ScanItem], [RiskTier: Int], Int) in
                let scoped = query.scoped(items)
                var counts: [RiskTier: Int] = [:]
                for i in scoped { counts[i.tier, default: 0] += 1 }
                let total = ItemQuery(scope: query.scope).scoped(items).count
                return (query.apply(to: items), counts, total)
            }.value
            guard !Task.isCancelled else { return }
            self?.rows = rows
            self?.tierCounts = counts
            self?.scopeCount = total
        }
    }
}
