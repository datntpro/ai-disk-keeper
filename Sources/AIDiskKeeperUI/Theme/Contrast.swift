import Foundation

/// A straight (non-premultiplied) sRGB colour, components 0…1. The one numeric colour type the theme and its
/// contrast tests share.
struct RGBA: Sendable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// 0…255 channels and an alpha of 0…1.
    init(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) {
        self.init(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255, a: a)
    }

    /// `0xRRGGBB`.
    init(hex: UInt32, a: Double = 1) {
        self.init(Int((hex >> 16) & 0xFF), Int((hex >> 8) & 0xFF), Int(hex & 0xFF), a)
    }
}

/// WCAG 2.x relative luminance and contrast, plus alpha compositing, so tokens that carry alpha (the `*Soft` fills)
/// are checked as they actually land on `surface` / `bg`.
func relativeLuminance(_ c: RGBA) -> Double {
    func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

func contrastRatio(_ a: RGBA, _ b: RGBA) -> Double {
    let la = relativeLuminance(a), lb = relativeLuminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// `top` painted over an opaque `under`.
func composite(_ top: RGBA, over under: RGBA) -> RGBA {
    RGBA(r: top.r * top.a + under.r * (1 - top.a),
         g: top.g * top.a + under.g * (1 - top.a),
         b: top.b * top.a + under.b * (1 - top.a), a: 1)
}

/// Label colour for text drawn on a solid fill: `text` or `onAccent` (white / near-black), whichever reaches 4.5:1.
/// `nil` when neither does.
func labelInk(onFill fill: RGBA, appearance: ADKAppearance) -> ADKColor? {
    [ADKColor.text, .onAccent]
        .map { ($0, contrastRatio($0.rgba(appearance), fill)) }
        .filter { $0.1 >= 4.5 }
        .max { $0.1 < $1.1 }?.0
}
