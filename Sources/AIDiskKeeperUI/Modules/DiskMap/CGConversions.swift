import CoreGraphics
import DiskKeeperCore

// Core's layout types carry no CoreGraphics; the UI converts at the edge.
extension LayoutRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(_ r: CGRect) { self.init(x: r.minX, y: r.minY, width: r.width, height: r.height) }
}

extension LayoutPoint {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    init(_ p: CGPoint) { self.init(x: p.x, y: p.y) }
}
