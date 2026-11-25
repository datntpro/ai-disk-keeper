import DiskKeeperCore

/// Aggregates over a set of items. Works mid-scan.
public struct ScanTotals: Sendable, Equatable {
    public var all: UsageTotals = .zero
    public var byTier: [RiskTier: UsageTotals] = [:]
    public var byTool: [ToolID: UsageTotals] = [:]
    public var byCategory: [ItemCategory: UsageTotals] = [:]
    /// Items T10 may let the user tick (`isSelectable`).
    public var selectable: UsageTotals = .zero
    /// Items "Select all Safe" may tick (`isBulkSelectable`).
    public var bulkSelectable: UsageTotals = .zero

    public init() {}

    public init(items: [ScanItem]) {
        for tier in RiskTier.allCases { byTier[tier] = .zero }
        for item in items {
            all.add(item)
            byTier[item.tier, default: .zero].add(item)
            byTool[item.tool, default: .zero].add(item)
            byCategory[item.category, default: .zero].add(item)
            if item.isSelectable { selectable.add(item) }
            if item.isBulkSelectable { bulkSelectable.add(item) }
        }
    }
}
