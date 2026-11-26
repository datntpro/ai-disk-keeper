import SwiftUI

/// One motion language: a smooth 0.45 s curve, replaced by a cross-fade (or nothing) under Reduce Motion.
enum StrataMotion {
    static let curve = Animation.smooth(duration: 0.45)

    /// `nil` under Reduce Motion: callers then cross-fade with `.transition(.opacity)`.
    static func animation(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : curve }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98))
    }

    /// cubic-bezier(.2, .8, .2, 1) evaluated at time `t` (0…1), for Canvas morphs. Clamped to 0…1.
    static func progress(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        let x1 = 0.2, y1 = 0.8, x2 = 0.2, y2 = 1.0
        func coord(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
        }
        func slope(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * p1 + 6 * u * s * (p2 - p1) + 3 * s * s * (1 - p2)
        }
        var s = t
        for _ in 0..<5 {
            let err = coord(s, x1, x2) - t
            let d = slope(s, x1, x2)
            if abs(d) < 1e-6 { break }
            s -= err / d
            s = min(max(s, 0), 1)
        }
        if abs(coord(s, x1, x2) - t) > 1e-6 {
            // Newton stalled (very flat start): fall back to bisection so the curve stays monotonic.
            var lo = 0.0, hi = 1.0
            for _ in 0..<30 {
                s = (lo + hi) / 2
                if coord(s, x1, x2) < t { lo = s } else { hi = s }
            }
        }
        return min(max(coord(s, y1, y2), 0), 1)
    }
}

struct StrataAnimationModifier<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(StrataMotion.animation(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// Animate changes of `value` with the Strata curve, or not at all under Reduce Motion.
    func strataAnimation<V: Equatable>(_ value: V) -> some View { modifier(StrataAnimationModifier(value: value)) }
}
