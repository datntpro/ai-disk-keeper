import Foundation

/// A point in layout space (points, y grows downwards). No CoreGraphics: the UI converts.
public struct LayoutPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// An axis-aligned rectangle in layout space. Containment is half-open: `[x, x+width) × [y, y+height)`.
public struct LayoutRect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var area: Double { width * height }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(_ p: LayoutPoint) -> Bool {
        p.x >= x && p.x < x + width && p.y >= y && p.y < y + height
    }

    /// Shrinks every side by `d` (never below zero size).
    public func inset(by d: Double) -> LayoutRect {
        let w = max(0, width - 2 * d), h = max(0, height - 2 * d)
        return LayoutRect(x: x + (width - w) / 2, y: y + (height - h) / 2, width: w, height: h)
    }

    var isFinite: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite }
}
