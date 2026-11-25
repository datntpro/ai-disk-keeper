import Foundation

/// Facts about a candidate item that `tierWhen` conditions are evaluated against.
public struct ItemFacts: Sendable, Hashable {
    public var lastModified: Date?
    public var sizeAllocated: Int64
    /// Names (from the rule's `markerExists` conditions) that exist next to / inside the item.
    public var existingMarkers: Set<String>

    public init(lastModified: Date? = nil, sizeAllocated: Int64 = 0, existingMarkers: Set<String> = []) {
        self.lastModified = lastModified
        self.sizeAllocated = sizeAllocated
        self.existingMarkers = existingMarkers
    }
}

public enum TierEvaluator {
    /// First matching `tierWhen` wins, else `rule.tier`. `matchedIndex` is the matched condition's index.
    public static func evaluate(
        _ rule: ScannerRule, facts: ItemFacts, now: Date
    ) -> (tier: RiskTier, matchedIndex: Int?) {
        for (i, when) in rule.tierWhen.enumerated() where holds(when.condition, facts: facts, now: now) {
            return (when.tier, i)
        }
        return (rule.tier, nil)
    }

    static func holds(_ c: TierCondition, facts: ItemFacts, now: Date) -> Bool {
        if c.olderThanDays != nil || c.newerThanDays != nil {
            guard let modified = facts.lastModified else { return false }
            let age = max(0, now.timeIntervalSince(modified))   // future mtime counts as age 0
            if let d = c.olderThanDays, !(age > d * 86_400) { return false }
            if let d = c.newerThanDays, !(age < d * 86_400) { return false }
        }
        if let mb = c.sizeOverMB, !(Double(facts.sizeAllocated) > mb * 1_000_000) { return false }
        if let m = c.markerExists, !facts.existingMarkers.contains(m) { return false }
        return true
    }
}
