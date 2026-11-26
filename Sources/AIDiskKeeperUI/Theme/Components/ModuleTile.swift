import DiskKeeperCore
import SwiftUI

/// A module entry point: icon, title, size, a tier-split mini bar and an optional badge.
struct ModuleTile: View {
    let symbol: String
    let title: String
    let bytes: Int64
    var tierSplit: [RiskTier: Int64] = [:]
    var badge: String?
    let action: () -> Void

    private var splitDescription: String {
        RiskTier.allCases.compactMap { tier in
            guard let b = tierSplit[tier], b > 0 else { return nil }
            return "\(Formatting.bytes(b)) \(TierStyle.style(for: tier).label)"
        }.joined(separator: ", ")
    }

    private var a11yLabel: String {
        let detail = [Formatting.bytes(bytes), splitDescription].filter { !$0.isEmpty }.joined(separator: ", ")
        return loc("tile.a11y", "\(title), \(detail)")
    }

    var body: some View {
        Button(action: action) {
            SectionCard {
                VStack(alignment: .leading, spacing: ADKTheme.Spacing.sm) {
                    HStack {
                        Image(systemName: symbol).symbolRenderingMode(.hierarchical)
                            .font(.title2).foregroundStyle(.adkAccent)
                        Spacer()
                        if let badge {
                            Text(badge).font(.caption.weight(.semibold)).foregroundStyle(.adkAccent)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(.adkAccentSoft, in: Capsule())
                        }
                    }
                    Text(title).font(ADKTheme.Font.headline).foregroundStyle(.adkText)
                    SizeText(bytes).font(.title3).foregroundStyle(.adkText)
                    TierSplitBar(split: tierSplit)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(.isButton)
    }
}

/// The 6 pt safe / review / keep mini bar, drawn in one Canvas.
private struct TierSplitBar: View {
    let split: [RiskTier: Int64]

    var body: some View {
        let parts = RiskTier.allCases.map { ($0, max(split[$0] ?? 0, 0)) }
        let total = parts.reduce(Int64(0)) { $0 + $1.1 }
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.adkSunken))
            guard total > 0 else { return }
            var x: CGFloat = 0
            for (tier, b) in parts where b > 0 {
                let w = size.width * CGFloat(b) / CGFloat(total)
                ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)),
                         with: .color(TierStyle.style(for: tier).color))
                x += w
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}
