import DiskKeeperCore
import Foundation

/// Geometry of the zoom morph: rectangles keyed by node id are interpolated over 0.45 s; nodes only in the new layout
/// fade in. Under Reduce Motion nothing moves: the whole map cross-fades over 0.2 s.
enum DiskMapTransitionMath {
    static let reduceMotionDuration: TimeInterval = 0.2

    /// Eased progress 0…1 for `elapsed` seconds into a morph.
    static func progress(elapsed: TimeInterval) -> Double {
        StrataMotion.progress(elapsed / ZoomTransition.duration)
    }

    /// Opacity of the whole map under Reduce Motion.
    static func crossFade(elapsed: TimeInterval) -> Double {
        min(1, max(0, elapsed / reduceMotionDuration))
    }

    /// Where `target` is drawn at progress `p`, and how opaque (nodes without an old rect fade in).
    static func frame(of target: LayoutRect, node: DiskNodeID?, from: [DiskNodeID: LayoutRect], progress p: Double)
        -> (rect: LayoutRect, opacity: Double) {
        guard let node, let old = from[node] else { return (target, p) }
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        return (LayoutRect(x: lerp(old.x, target.x), y: lerp(old.y, target.y),
                           width: lerp(old.width, target.width), height: lerp(old.height, target.height)), 1)
    }
}
