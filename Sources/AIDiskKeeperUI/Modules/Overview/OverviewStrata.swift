import DiskKeeperCore
import SwiftUI

/// The whole disk as one strata bar: what the scan found by layer, "Everything else", and the free space.
struct OverviewStrata: View {
    let storage: StorageModel
    let scan: ScanViewModel
    let care: CareScanModel

    /// Layers from the found items (the rule engine already counts each byte once) plus the apps total, then
    /// "Everything else" = used − found, never negative. Before any scan: just "Used".
    static func segments(items: [ScanItem], appsBytes: Int64, used: Int64, scanned: Bool) -> [StrataSegment] {
        guard scanned else { return [StrataSegment(id: "overview.used", layer: .other, bytes: max(0, used), label: OverviewCopy.strataUsed)] }
        var byLayer: [StrataLayer: Int64] = [:]
        for item in items { byLayer[StrataLayer(category: item.category), default: 0] += item.sizeAllocated }
        byLayer[.apps, default: 0] += appsBytes
        var out: [StrataSegment] = []
        var found: Int64 = 0
        for layer in [StrataLayer.ai, .worktree, .build, .model, .docker, .junk, .apps] {
            guard let bytes = byLayer[layer], bytes > 0 else { continue }
            out.append(StrataSegment(id: "overview.\(layer)", layer: layer, bytes: bytes, label: layer.title))
            found += bytes
        }
        let rest = max(0, used - found)
        if rest > 0 {
            out.append(StrataSegment(id: "overview.rest", layer: .other, bytes: rest, label: OverviewCopy.strataEverythingElse))
        }
        return out
    }

    var body: some View {
        // Never draw zeros: without a measurement there is no bar.
        if let total = storage.totalBytes, let used = storage.usedBytes {
            let segments = Self.segments(items: scan.items.filter { $0.category != .application && $0.category != .appLeftover && $0.category != .startupItem },
                                         appsBytes: care.summaries[.apps]?.totalBytes ?? 0, used: used, scanned: care.phase != .before)
            SectionCard {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.md) {
                    StrataBar(segments: segments, total: total, free: storage.freeBytes)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(segments) { s in
                            LegendChip(color: s.layer.color, label: "\(s.label) \(Formatting.bytes(s.bytes))")
                        }
                        if let free = storage.freeBytes {
                            LegendChip(color: .adkLine, label: "\(loc("storage.layer.free", "Free")) \(Formatting.bytes(free))")
                        }
                    }
                }
            }
        }
    }
}
