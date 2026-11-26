import DiskKeeperCore
import SwiftUI

/// The tier shape: Safe ● filled circle, Review ◆ diamond, Keep ○ ring. Shape + text + colour, never colour alone.
struct TierGlyph: View {
    enum Kind: Sendable, Hashable {
        case safe, review, keep
        init(_ tier: RiskTier) {
            switch tier {
            case .safe: self = .safe
            case .review: self = .review
            case .keep: self = .keep
            }
        }
    }

    let kind: Kind
    var color: Color
    var size: CGFloat = 7

    var body: some View {
        Group {
            switch kind {
            case .safe:
                Circle().fill(color)
            case .review:
                RoundedRectangle(cornerRadius: 1.5).fill(color).rotationEffect(.degrees(45)).scaleEffect(0.78)
            case .keep:
                Circle().strokeBorder(color, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
