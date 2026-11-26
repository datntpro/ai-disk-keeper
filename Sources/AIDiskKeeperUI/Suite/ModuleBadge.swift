import DiskKeeperCore

/// The small trailing number on a sidebar row. Computed from model state, never stored.
public enum ModuleBadge: Equatable, Sendable {
    case bytes(Int64)
    case count(Int)

    var text: String {
        switch self {
        case .bytes(let n): Formatting.bytes(n)
        case .count(let n): Formatting.count(n)
        }
    }

    var a11yText: String {
        switch self {
        case .bytes: loc("module.badge.bytes.a11y", "\(text) reclaimable")
        case .count: loc("module.badge.count.a11y", "\(text) items")
        }
    }

    /// Σ allocated bytes of the non-Keep items in `categories`, read from the running totals (no pass over items).
    /// `nil` when there is nothing to show.
    static func reclaimable(_ totals: ScanTotals, categories: Set<ItemCategory>) -> ModuleBadge? {
        let bytes = categories.reduce(Int64(0)) { $0 + (totals.reclaimableByCategory[$1]?.allocatedBytes ?? 0) }
        return bytes > 0 ? .bytes(bytes) : nil
    }
}
