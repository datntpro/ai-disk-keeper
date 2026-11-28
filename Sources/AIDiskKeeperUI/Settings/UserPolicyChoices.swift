import DiskKeeperCore

/// Which tiers the item menu may offer: only stricter ones. A user can never loosen a tier.
enum UserPolicyChoices {
    static func offered(for tier: RiskTier) -> [RiskTier] {
        switch tier {
        case .safe: [.review, .keep]
        case .review: [.keep]
        case .keep: []
        }
    }
}
