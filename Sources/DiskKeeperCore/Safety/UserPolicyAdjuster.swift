import Foundation

/// Applies the user's ignore list, per-rule switches and tier overrides after a scan. Monotone (see ``ItemAdjuster``):
/// it drops items and moves tiers toward Keep only. A looser override (Keep→Review, anything→Safe) is ignored and
/// reported once; unknown ids are harmless. Register it before ``InUseAdjuster``.
public struct UserPolicyAdjuster: ItemAdjuster {
    public let name = "user-policy"
    private let policy: UserPolicy

    public init(policy: UserPolicy) { self.policy = policy }

    public func adjust(_ items: [ScanItem], context: ScanContext) async -> (items: [ScanItem], warnings: [ScanWarning]) {
        guard !policy.isEmpty else { return (items, []) }
        var looser = Set<String>()
        var out: [ScanItem] = []
        out.reserveCapacity(items.count)
        for var item in items {
            if policy.hides(item) { continue }
            if let o = policy.override(for: item) {
                if o > item.tier {
                    item.tier = o
                } else if o < item.tier {
                    looser.insert(policy.tierOverrides[item.id] != nil ? item.id : item.ruleID)
                }
            }
            out.append(item)
        }
        let warnings = looser.sorted().map {
            ScanWarning(kind: .other, ruleID: nil,
                        message: "Ignored a tier override for \($0): overrides can only make an item stricter.",
                        code: .looserOverrideIgnored(key: $0))
        }
        return (out, warnings)
    }
}
