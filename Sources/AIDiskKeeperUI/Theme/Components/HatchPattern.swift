import SwiftUI

/// Diagonal hatching (135°, a line every 7 pt, 1 pt wide): free space, and protected map nodes.
struct HatchPattern: Shape {
    static let spacing: CGFloat = 7
    static let lineWidth: CGFloat = 1

    func path(in rect: CGRect) -> Path { Self.path(in: rect) }

    /// One path for the whole rect.
    static func path(in rect: CGRect) -> Path {
        var p = Path()
        guard rect.width > 0, rect.height > 0 else { return p }
        let h = rect.height
        var x = rect.minX - h
        while x < rect.maxX {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + h, y: rect.minY))
            x += spacing
        }
        return p
    }

    /// For Canvas: clips to `rect` and strokes one `Path`.
    static func draw(in context: GraphicsContext, rect: CGRect, color: Color) {
        var c = context
        c.clip(to: Path(rect))
        c.stroke(path(in: rect), with: .color(color), lineWidth: lineWidth)
    }
}

