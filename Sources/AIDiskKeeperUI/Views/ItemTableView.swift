import DiskKeeperCore
import SwiftUI

struct ItemTableView: View {
    let rows: [ScanItem]           // already filtered and sorted (see ItemListModel)
    let tierCounts: [RiskTier: Int]
    @Binding var query: ItemQuery
    @Binding var inspectedID: ScanItem.ID?
    /// T10: nil hides the checkbox column and the "Select all Safe" button.
    var selection: SelectionModel? = nil
    var scopeName: String? = nil
    /// Shown over the table body (below the chips and search field) when a search matches nothing.
    var filteredEmpty: FilteredEmpty? = nil

    private var sortOrder: Binding<[ItemSortComparator]> {
        Binding(
            get: { ItemTableSort.comparators(for: query.sort) },
            set: { new in if let sort = ItemTableSort.sort(from: new) { query.sort = sort } })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(RiskTier.allCases, id: \.self) { tier in
                    let s = TierStyle.style(for: tier)
                    let count = tierCounts[tier] ?? 0
                    Toggle(isOn: Binding(get: { query.tiers.contains(tier) },
                                         set: { on in if on { query.tiers.insert(tier) } else { query.tiers.remove(tier) } })) {
                        Label(loc("filter.tierCount", "\(s.label) \(count)"), systemImage: s.symbolName).fixedSize()
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel(loc("filter.tierA11y", "\(s.label) items, \(count)"))
                }
                if let selection {
                    SelectAllSafeButton(items: rows, scopeName: scopeName, selection: selection)
                }
                Spacer()
                TextField(loc("search.placeholder", "Search name or path"), text: $query.searchText)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 140, idealWidth: 200, maxWidth: 240)
                    .accessibilityLabel(loc("search.a11y", "Search items by name or path"))
            }
            .padding(8)
            Table(rows, selection: $inspectedID, sortOrder: sortOrder) {
                TableColumn(CleanupCopy.selectColumn) { item in
                    if let selection { SelectionCheckbox(item: item, selection: selection) }
                }.width(28)
                TableColumn(loc("column.name", "Name"), sortUsing: ItemSortComparator(key: .name, order: .forward)) { item in
                    HStack(spacing: 6) {
                        Text(item.uiNameWithProject()).lineLimit(1)
                        if item.isSelectable, let bundleID = item.requiresAppQuit { QuitAppBadge(bundleID: bundleID) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(item.a11yLabel)
                }.width(min: 180, ideal: 260)
                TableColumn(loc("column.size", "Size"), sortUsing: ItemSortComparator(key: .size)) { item in
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Formatting.bytes(item.sizeAllocated)).monospacedDigit()
                        if let r = ReclaimCopy.compact(for: ReclaimEstimate.make(items: [item])) {
                            Text(r).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(min: 70, ideal: 80, max: 100)
                TableColumn(loc("column.lastUsed", "Last used"), sortUsing: ItemSortComparator(key: .lastUsed)) { item in
                    Text(Formatting.relative(item.lastModified)).foregroundStyle(.secondary)
                }.width(min: 110, ideal: 130, max: 170)
                TableColumn(loc("column.tier", "Tier"), sortUsing: ItemSortComparator(key: .tier)) { item in TierBadge(tier: item.tier) }
                    .width(min: 100, ideal: 120, max: 150)
                TableColumn(loc("column.path", "Path")) { item in
                    Text(item.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.width(min: 120, ideal: 220)
            }
            .overlay {
                if let filteredEmpty {
                    StateView(kind: .filteredEmpty, symbol: "magnifyingglass", title: filteredEmpty.title,
                              message: StateCopy.filteredBody,
                              actions: [StateAction(title: StateCopy.filteredClear) { query.searchText = "" }])
                        .background(.background)
                }
            }
        }
    }
}

struct FilteredEmpty: Equatable { let title: String }

/// Column comparator that carries an `ItemSortKey`, so `Table` sorting maps straight to `ItemSort`.
struct ItemSortComparator: SortComparator, Hashable, Sendable {
    var key: ItemSortKey
    var order: SortOrder = .reverse

    func compare(_ lhs: ScanItem, _ rhs: ScanItem) -> ComparisonResult {
        // The real ordering (with id tie-break) lives in ItemQuery; this only serves Table's own bookkeeping.
        let q = ItemQuery(sort: ItemSort(key: key, ascending: order == .forward))
        let sorted = q.apply(to: [lhs, rhs])
        return sorted.first?.id == lhs.id ? .orderedAscending : .orderedDescending
    }
}

enum ItemTableSort {
    static func comparators(for sort: ItemSort) -> [ItemSortComparator] {
        [ItemSortComparator(key: sort.key, order: sort.ascending ? .forward : .reverse)]
    }

    static func sort(from comparators: [ItemSortComparator]) -> ItemSort? {
        comparators.first.map { ItemSort(key: $0.key, ascending: $0.order == .forward) }
    }
}
