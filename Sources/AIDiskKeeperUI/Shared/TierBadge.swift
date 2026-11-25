import DiskKeeperCore
import SwiftUI

struct TierBadge: View {
    let tier: RiskTier
    var body: some View {
        let s = TierStyle.style(for: tier)
        Label(s.label, systemImage: s.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(s.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(s.color.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(loc("tier.a11y", "Tier: \(s.label)"))
            .accessibilityHint(s.shortExplanation)
    }
}
