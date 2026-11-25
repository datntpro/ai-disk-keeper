import Foundation

/// How cautious the app is about an item. Raw values match the rule JSON `"tier"` field.
public enum RiskTier: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case safe, review, keep

    var rank: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .keep: 2
        }
    }

    /// Ordered by caution: safe < review < keep.
    public static func < (lhs: RiskTier, rhs: RiskTier) -> Bool { lhs.rank < rhs.rank }

    /// Returns the more cautious of the two tiers. Callers may only *raise* a tier.
    public func escalated(to other: RiskTier) -> RiskTier { other.rank > rank ? other : self }

    /// Keep items are never selectable for cleanup.
    public var isSelectable: Bool { self != .keep }

    /// Only Safe items may be bulk-selected ("Select all Safe").
    public var isBulkSelectable: Bool { self == .safe }
}
