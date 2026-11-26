import AppKit
import SwiftUI

/// The menu bar glyph: three rounded bars (strata), drawn in code as a monochrome template image.
/// Constants mirror the `glyph` block of `Packaging/Icon/StrataMark.json`; `StrataGlyphTests` checks the parity.
enum StrataGlyph {
    static let barCount = 3
    static let barHeight: CGFloat = 3
    static let gap: CGFloat = 2
    static let radius: CGFloat = 1.5
    static let left: CGFloat = 2
    static let bottom: CGFloat = 3
    static let topBarWidth: CGFloat = 9
    static let barWidth: CGFloat = 14
    static let basePointSize: CGFloat = 18

    static var accessibilityDescription: String { loc("menubar.glyph.a11y", "AI Disk Keeper") }

    /// 18×18 pt template image: 3 rounded bars, top bar shorter.
    static func image(pointSize: CGFloat = 18) -> NSImage {
        make(topWidth: topBarWidth, pointSize: pointSize)
    }

    /// Same glyph; the top bar's length is the free fraction (clamped 0…1) of a full bar.
    static func gaugeImage(freeFraction: Double, pointSize: CGFloat = 18) -> NSImage {
        let f = CGFloat(min(max(freeFraction.isNaN ? 0 : freeFraction, 0), 1))
        return make(topWidth: barWidth * f, pointSize: pointSize)
    }

    /// Draws the three bars into the current context (black). `scale` is `pointSize / 18`.
    static func drawBars(topWidth: CGFloat, scale: CGFloat = 1) {
        NSColor.black.setFill()
        for i in 0..<barCount {
            // i = 0 is the top bar. Pitch 5 pt keeps every edge on a whole pixel at 1× and 2×.
            let y = bottom + CGFloat(barCount - 1 - i) * (barHeight + gap)
            let w = i == 0 ? topWidth : barWidth
            guard w > 0 else { continue }
            let rect = NSRect(x: left * scale, y: y * scale, width: w * scale, height: barHeight * scale)
            NSBezierPath(roundedRect: rect, xRadius: min(radius * scale, w * scale / 2), yRadius: radius * scale).fill()
        }
    }

    /// Live strata: each bar is a meter (0…1) over a faint track. Missing bars show an empty track.
    static func drawMeters(_ levels: [CGFloat]) {
        for i in 0..<barCount {
            let y = bottom + CGFloat(barCount - 1 - i) * (barHeight + gap)
            let track = NSRect(x: left, y: y, width: barWidth, height: barHeight)
            NSColor.black.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
            let level = i < levels.count ? min(max(levels[i], 0), 1) : 0
            guard level > 0 else { continue }
            let w = max(barWidth * level, barHeight)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: left, y: y, width: w, height: barHeight), xRadius: radius, yRadius: radius).fill()
        }
    }

    private static func make(topWidth: CGFloat, pointSize: CGFloat) -> NSImage {
        let scale = pointSize / basePointSize
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { _ in
            drawBars(topWidth: topWidth, scale: scale)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}

#Preview("Strata glyph") {
    HStack(spacing: 16) {
        Image(nsImage: StrataGlyph.image())
        Image(nsImage: StrataGlyph.gaugeImage(freeFraction: 0.4))
    }
    .padding(20)
}
