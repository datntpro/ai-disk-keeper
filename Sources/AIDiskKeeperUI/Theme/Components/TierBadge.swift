import DiskKeeperCore
import SwiftUI

/// Tier badge v2: glyph + label in a soft capsule. Under Increase Contrast the fill is solid with a border.
struct TierBadge: View {
    let tier: RiskTier
    var compact = false
    @Environment(\.adkIncreasedContrast) private var increasedContrast

    var body: some View {
        let s = TierStyle.style(for: tier)
        HStack(spacing: compact ? 4 : 5) {
            TierGlyph(kind: s.glyph, color: s.ink)
            if !compact { Text(s.label) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(s.ink)
        .padding(.horizontal, compact ? 6 : 8).padding(.vertical, 2)
        .background(s.softFill, in: Capsule())
        .overlay { if increasedContrast { Capsule().strokeBorder(.adkLineStrong, lineWidth: ADKTheme.hairline) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(loc("tier.a11y", "Tier: \(s.label)"))
        .accessibilityHint(s.shortExplanation)
    }
}
