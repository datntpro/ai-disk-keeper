import DiskKeeperCore
import SwiftUI

/// The one source of truth for tier copy, icon and colour. Colour is never the only signal.
public struct TierStyle: Sendable {
    public let tier: RiskTier
    public let label: String
    public let symbolName: String
    public let color: Color
    public let shortExplanation: String
    public let longExplanation: String

    public static func style(for tier: RiskTier) -> TierStyle {
        switch tier {
        case .safe:
            TierStyle(
                tier: tier, label: loc("tier.safe.label", "Safe"), symbolName: "checkmark.shield", color: .green,
                shortExplanation: loc("tier.safe.short", "Safe to clean. It's rebuilt automatically or holds nothing you need."),
                longExplanation: loc("tier.safe.long", "Caches, temporary files and old data the tool regenerates on its own. Cleaning it moves it to the Trash and costs you nothing except, sometimes, a slower first launch."))
        case .review:
            TierStyle(
                tier: tier, label: loc("tier.review.label", "Review"), symbolName: "exclamationmark.triangle", color: .orange,
                shortExplanation: loc("tier.review.short", "Probably safe, but cleaning it costs something. Check it yourself."),
                longExplanation: loc("tier.review.long", "Things like old chat or session history you can no longer resume, a model you'd have to download again, or dependencies you'd have to reinstall. Read the explanation, then tick each item yourself. Review items are never selected in bulk."))
        case .keep:
            TierStyle(
                tier: tier, label: loc("tier.keep.label", "Keep"), symbolName: "lock.fill", color: .secondary,
                shortExplanation: loc("tier.keep.short", "Shown so you know where space goes. Not cleanable."),
                longExplanation: loc("tier.keep.long", "Recent, in use, or holding work that isn't saved anywhere else (for example uncommitted changes). AI Disk Keeper will not clean it."))
        }
    }
}
