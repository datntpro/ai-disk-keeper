import Foundation

/// A post-scan pass that may only make an item more cautious. Runs once over the finished item list.
///
/// Contract (enforced by ``AdjusterValidation``): same ids, paths, sizes and `cleanupMethod`; the tier may only move
/// toward `.keep` (never up to Safe); no item added, items may be dropped. A violation discards that adjuster's output.
public protocol ItemAdjuster: Sendable {
    var name: String { get }
    func adjust(_ items: [ScanItem], context: ScanContext) async -> (items: [ScanItem], warnings: [ScanWarning])
}

enum AdjusterValidation {
    /// True when `after` is a legal result of adjusting `before`.
    static func isMonotonic(before: [ScanItem], after: [ScanItem]) -> Bool {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<ScanItem.ID>()
        for n in after {
            guard let o = old[n.id], seen.insert(n.id).inserted else { return false }
            guard n.url == o.url, n.sizeAllocated == o.sizeAllocated, n.sizeLogical == o.sizeLogical,
                  n.fileCount == o.fileCount, n.cleanupMethod == o.cleanupMethod, n.ruleID == o.ruleID,
                  n.tier >= o.tier else { return false }   // RiskTier order: safe < review < keep
        }
        return true
    }
}
