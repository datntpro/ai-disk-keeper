import AppKit
import DiskKeeperCore
import Foundation

/// Everything that decides the label's pixels. Equal content = no re-render.
struct LabelContent: Equatable {
    var layout: MenuBarLayout.Result
    /// Per metric, last ~24 samples quantized to 0…12 (network: down levels; `ridgeUp` has the upload).
    var ridges: [MetricID: [UInt8]] = [:]
    var ridgeUp: [UInt8] = []
    /// Live strata meters (0…12 per bar, top to bottom).
    var meters: [UInt8] = []
    var pressureDot = false

    static func quantize(_ v: Double) -> UInt8 { UInt8((min(max(v.isNaN ? 0 : v, 0), 1) * 12).rounded()) }
}

/// Draws the whole item into one template `NSImage` (black on clear: the menu bar tints it). No colour, ever.
enum MenuBarLabelRenderer {
    static let height: CGFloat = 18

    static func render(_ c: LabelContent) -> NSImage {
        // The T47 item with no text is the glyph itself: same image, same pixels.
        if c.layout.mode == .glyph, c.layout.cells.count == 1 { return StrataGlyph.image() }
        let size = NSSize(width: max(c.layout.width, 1), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            var x: CGFloat = 0
            let gap = c.layout.mode == .glyph ? 4 : MenuBarLayout.spacing
            for cell in c.layout.cells {
                draw(cell, at: x, content: c)
                x += cell.width + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = StrataGlyph.accessibilityDescription
        return image
    }

    private static func draw(_ cell: MenuBarLayout.Cell, at x: CGFloat, content c: LabelContent) {
        switch cell.kind {
        case .glyph:
            if c.layout.mode == .strata {
                StrataGlyph.drawMeters(c.meters.map { CGFloat($0) / 12 })
            } else {
                StrataGlyph.drawBars(topWidth: StrataGlyph.topBarWidth)
            }
        case .separator:
            NSBezierPath(rect: NSRect(x: x, y: 4, width: 1, height: 10)).fill()
        case .metric(let m):
            var cursor = x
            if cell.showsMark { drawMark(m, at: cursor); cursor += MenuBarLayout.markWidth + MenuBarLayout.spacing }
            if cell.showsRidge {
                drawRidge(m, in: NSRect(x: cursor, y: 2, width: MenuBarLayout.ridgeWidth, height: 14), content: c)
                cursor += MenuBarLayout.ridgeWidth + MenuBarLayout.spacing
            }
            if let text = cell.text {
                let attrs: [NSAttributedString.Key: Any] = [.font: MenuBarLayout.font, .foregroundColor: NSColor.black]
                let s = NSAttributedString(string: text, attributes: attrs)
                s.draw(at: NSPoint(x: cursor, y: (height - s.size().height) / 2))
                if m == .memory, c.pressureDot {
                    let w = s.size().width
                    NSBezierPath(ovalIn: NSRect(x: cursor + w + 2, y: height / 2 - 1.5, width: 3, height: 3)).fill()
                }
            }
        }
    }

    private static func drawMark(_ m: MetricID, at x: CGFloat) {
        let name = m == .cpu ? "cpu" : m == .memory ? "memorychip" : "arrow.up.arrow.down"
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular)) else { return }
        let s = symbol.size
        let scale = min(MenuBarLayout.markWidth / max(s.width, 1), MenuBarLayout.markWidth / max(s.height, 1), 1)
        let w = s.width * scale, h = s.height * scale
        symbol.draw(in: NSRect(x: x + (MenuBarLayout.markWidth - w) / 2, y: (height - h) / 2, width: w, height: h))
    }

    private static func drawRidge(_ m: MetricID, in r: NSRect, content c: LabelContent) {
        func path(_ levels: [UInt8], base: CGFloat, direction: CGFloat, span: CGFloat) -> NSBezierPath? {
            guard levels.count > 1 else { return nil }
            let p = NSBezierPath()
            let step = r.width / CGFloat(max(levels.count - 1, 1))
            p.move(to: NSPoint(x: r.minX, y: base))
            for (i, l) in levels.enumerated() {
                p.line(to: NSPoint(x: r.minX + CGFloat(i) * step, y: base + direction * span * CGFloat(l) / 12))
            }
            p.line(to: NSPoint(x: r.maxX, y: base))
            p.close()
            return p
        }
        if m == .network {
            let mid = r.midY
            NSColor.black.withAlphaComponent(0.8).setFill()
            path(c.ridges[.network] ?? [], base: mid, direction: -1, span: r.height / 2)?.fill()
            NSColor.black.withAlphaComponent(0.38).setFill()
            path(c.ridgeUp, base: mid, direction: 1, span: r.height / 2)?.fill()
        } else {
            NSColor.black.withAlphaComponent(0.55).setFill()
            path(c.ridges[m] ?? [], base: r.minY, direction: 1, span: r.height)?.fill()
        }
    }
}
