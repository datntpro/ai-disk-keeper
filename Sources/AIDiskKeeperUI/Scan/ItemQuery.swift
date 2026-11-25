import Foundation
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

public enum ItemSortKey: Sendable, Hashable { case size, name, lastUsed, tier }

public struct ItemSort: Sendable, Hashable {
    public var key: ItemSortKey
    public var ascending: Bool
    public init(key: ItemSortKey = .size, ascending: Bool = false) {
        self.key = key
        self.ascending = ascending
    }
    /// Largest first.
    public static let `default` = ItemSort()
}

/// Pure filter / sort logic for the item table.
public struct ItemQuery: Sendable, Equatable {
    public var scope: SidebarSelection
    public var tiers: Set<RiskTier>
    public var searchText: String
    public var sort: ItemSort

    public init(scope: SidebarSelection = .overview, tiers: Set<RiskTier> = Set(RiskTier.allCases),
                searchText: String = "", sort: ItemSort = .default) {
        self.scope = scope
        self.tiers = tiers
        self.searchText = searchText
        self.sort = sort
    }

    /// Items in scope (sidebar + search), ignoring the tier filter. Used for the tier chip counts.
    public func scoped(_ items: [ScanItem]) -> [ScanItem] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            switch scope {
            case .overview: break
            case .tool(let t): if item.tool != t { return false }
            case .category(let c): if item.category != c { return false }
            case .warnings: return false
            }
            guard !needle.isEmpty else { return true }
            return item.displayName.localizedCaseInsensitiveContains(needle)
                || item.path.localizedCaseInsensitiveContains(needle)
        }
    }

    public func apply(to items: [ScanItem]) -> [ScanItem] {
        scoped(items).filter { tiers.contains($0.tier) }.sorted(by: areInOrder)
    }

    public func totals(for items: [ScanItem]) -> ScanTotals { ScanTotals(items: apply(to: items)) }

    private func areInOrder(_ a: ScanItem, _ b: ScanItem) -> Bool {
        let result: ComparisonResult
        switch sort.key {
        case .size: result = compare(a.sizeAllocated, b.sizeAllocated)
        case .name: result = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
        case .lastUsed: result = compare(a.lastModified ?? .distantPast, b.lastModified ?? .distantPast)
        case .tier: result = compare(a.tier, b.tier)
        }
        if result == .orderedSame { return a.id < b.id }
        return sort.ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
