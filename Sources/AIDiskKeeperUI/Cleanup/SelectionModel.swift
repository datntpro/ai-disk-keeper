import DiskKeeperCore
import Foundation
import Observation

/// What the user has ticked. There is deliberately no bulk API for Review or Keep items.
@MainActor @Observable
public final class SelectionModel {
    public private(set) var selectedIDs: Set<ScanItem.ID> = []

    public init() {}

    public func isSelectable(_ item: ScanItem) -> Bool { item.isSelectable }
    public func isSelected(_ item: ScanItem) -> Bool { selectedIDs.contains(item.id) }

    /// Ignores items that are not selectable (Keep, report-only).
    public func toggle(_ item: ScanItem) {
        guard item.isSelectable else { return }
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
    }

    public func setSelected(_ item: ScanItem, _ on: Bool) {
        guard item.isSelectable else { return }
        if on { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
    }

    /// Adds ONLY Safe, bulk-selectable items (never Review, Keep or model weights) from `items`.
    public func selectAllSafe(in items: [ScanItem]) {
        for item in items where item.isBulkSelectable { selectedIDs.insert(item.id) }
    }

    public func deselectAll() { selectedIDs = [] }

    @ObservationIgnored private var generation: Int?

    /// Clears the selection when a new scan generation starts. Call with `scan.scanGeneration` on every change.
    public func syncScanGeneration(_ g: Int) {
        if let last = generation, last != g { selectedIDs = [] }
        generation = g
    }

    /// Resolves ids against the CURRENT scan; ids no longer present are dropped.
    public func selectedItems(from vm: ScanViewModel) -> [ScanItem] {
        selectedItems(in: vm.items)
    }

    public func selectedItems(in items: [ScanItem]) -> [ScanItem] {
        items.filter { selectedIDs.contains($0.id) && $0.isSelectable }
    }

    public func summary(in items: [ScanItem]) -> (count: Int, bytes: Int64, reviewCount: Int) {
        let sel = selectedItems(in: items)
        return (sel.count, sel.reduce(0) { $0 + $1.sizeAllocated }, sel.filter { $0.tier == .review }.count)
    }

    public func summary(from vm: ScanViewModel) -> (count: Int, bytes: Int64, reviewCount: Int) {
        summary(in: vm.items)
    }
}
