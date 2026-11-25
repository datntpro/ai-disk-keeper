import DiskKeeperCore
import SwiftUI

struct ItemTableView: View {
    let items: [ScanItem]          // all items; filtering happens here
    @Binding var query: ItemQuery
    @Binding var inspectedID: ScanItem.ID?

    private var sortOrder: Binding<[ItemSortComparator]> {
        Binding(
            get: { ItemTableSort.comparators(for: query.sort) },
            set: { new in if let sort = ItemTableSort.sort(from: new) { query.sort = sort } })
    }

    var body: some View {
        let rows = query.apply(to: items)
        let scoped = query.scoped(items)
        VStack(spacing: 0) {
            HStack {
                ForEach(RiskTier.allCases, id: \.self) { tier in
                    let s = TierStyle.style(for: tier)
                    let count = scoped.filter { $0.tier == tier }.count
                    Toggle(isOn: Binding(get: { query.tiers.contains(tier) },
                                         set: { on in if on { query.tiers.insert(tier) } else { query.tiers.remove(tier) } })) {
                        Label("\(s.label) \(count)", systemImage: s.symbolName)
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel("\(s.label) items, \(count)")
                }
                Spacer()
                TextField("Search name or path", text: $query.searchText)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
            .padding(8)
            Table(rows, selection: $inspectedID, sortOrder: sortOrder) {
                TableColumn("Name", sortUsing: ItemSortComparator(key: .name)) { item in
                    Text(item.nameWithProject).lineLimit(1)
                        .accessibilityLabel(item.a11yLabel)
                }
                TableColumn("Size", sortUsing: ItemSortComparator(key: .size)) { item in
                    Text(Formatting.bytes(item.sizeAllocated)).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(min: 70, ideal: 90)
                TableColumn("Last used", sortUsing: ItemSortComparator(key: .lastUsed)) { item in
                    Text(Formatting.relative(item.lastModified)).foregroundStyle(.secondary)
                }.width(min: 90, ideal: 120)
                TableColumn("Tier", sortUsing: ItemSortComparator(key: .tier)) { item in TierBadge(tier: item.tier) }
                    .width(min: 80, ideal: 100)
                TableColumn("Path") { item in
                    Text(item.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

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
