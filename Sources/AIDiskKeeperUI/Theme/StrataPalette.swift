import Foundation

/// The raw numbers behind every Strata colour: one switch per token, no dictionaries on the hot path. The contrast
/// tests read these same values, so there is no second source of truth.
enum StrataPalette {
    private static func pick(_ a: ADKAppearance, _ light: RGBA, _ dark: RGBA) -> RGBA { a.isDark ? dark : light }

    /// Ink on a solid (Increase Contrast) tier fill, chosen so it reaches 4.5:1. `ContrastTests` pins these.
    private static func hcInk(_ a: ADKAppearance, lightHC: RGBA) -> RGBA {
        a == .highContrastLight ? lightHC : RGBA(hex: 0x0C0E12)
    }

    private static let white = RGBA(hex: 0xFFFFFF)
    private static let nearBlack = RGBA(hex: 0x0C0E12)

    static func rgba(_ token: ADKColor, _ a: ADKAppearance) -> RGBA {
        let hc = a.isHighContrast
        switch token {
        case .bg: return pick(a, RGBA(hex: 0xF5F3EF), RGBA(hex: 0x111318))
        case .surface: return pick(a, RGBA(hex: 0xFFFFFF), RGBA(hex: 0x181B21))
        case .surface2: return pick(a, RGBA(hex: 0xFAF8F5), RGBA(hex: 0x1D2128))
        case .sunken: return pick(a, RGBA(hex: 0xEFECE6), RGBA(hex: 0x0C0E12))
        case .line:
            if hc { return rgba(.lineStrong, a) }
            return pick(a, RGBA(24, 22, 18, 0.09), RGBA(255, 255, 255, 0.075))
        case .lineStrong: return pick(a, RGBA(24, 22, 18, 0.16), RGBA(255, 255, 255, 0.14))
        case .text: return pick(a, RGBA(hex: 0x16181D), RGBA(hex: 0xECEEF2))
        case .text2:
            if hc { return pick(a, RGBA(hex: 0x3F4450), RGBA(hex: 0xC4C9D3)) }
            return pick(a, RGBA(hex: 0x585E6B), RGBA(hex: 0xA6ACB8))
        case .text3:
            // Light base is #868B96 (plan: #8B909B, which is 2.9:1 on `bg`; the caption floor is 3:1).
            if hc { return pick(a, RGBA(hex: 0x5C616C), RGBA(hex: 0xA6ACB8)) }
            return pick(a, RGBA(hex: 0x868B96), RGBA(hex: 0x727987))
        case .accent: return pick(a, RGBA(hex: 0x0B847B), RGBA(hex: 0x3DCBBE))
        case .accentHover: return pick(a, RGBA(hex: 0x08706A), RGBA(hex: 0x5ED8CC))
        case .accentSoft: return pick(a, RGBA(11, 132, 123, 0.11), RGBA(61, 203, 190, 0.14))
        case .onAccent: return pick(a, RGBA(hex: 0xFFFFFF), RGBA(hex: 0x04201D))
        case .focus: return pick(a, RGBA(11, 132, 123, 0.45), RGBA(61, 203, 190, 0.5))

        case .safe: return pick(a, RGBA(hex: 0x22A060), RGBA(hex: 0x3CC77E))
        case .safeInk:
            if hc { return hcInk(a, lightHC: nearBlack) }
            return pick(a, RGBA(hex: 0x136B3E), RGBA(hex: 0x7BE0A8))
        case .safeSoft:
            if hc { return rgba(.safe, a) }
            return pick(a, RGBA(34, 160, 96, 0.13), RGBA(60, 199, 126, 0.15))
        case .review: return pick(a, RGBA(hex: 0xD69412), RGBA(hex: 0xF0B232))
        case .reviewInk:
            if hc { return hcInk(a, lightHC: nearBlack) }
            return pick(a, RGBA(hex: 0x7E5300), RGBA(hex: 0xF5CA6E))
        case .reviewSoft:
            if hc { return rgba(.review, a) }
            return pick(a, RGBA(214, 148, 18, 0.16), RGBA(240, 178, 50, 0.15))
        case .keep: return pick(a, RGBA(hex: 0x5B66C9), RGBA(hex: 0x8A94F0))
        case .keepInk:
            if hc { return hcInk(a, lightHC: white) }
            return pick(a, RGBA(hex: 0x3A43A0), RGBA(hex: 0xAEB5F6))
        case .keepSoft:
            if hc { return rgba(.keep, a) }
            return pick(a, RGBA(91, 102, 201, 0.13), RGBA(138, 148, 240, 0.16))
        case .danger: return pick(a, RGBA(hex: 0xC9452F), RGBA(hex: 0xF0705A))
        case .dangerInk:
            if hc { return hcInk(a, lightHC: white) }
            return pick(a, RGBA(hex: 0x9A2E1C), RGBA(hex: 0xF59A88))
        case .dangerSoft:
            if hc { return rgba(.danger, a) }
            return pick(a, RGBA(201, 69, 47, 0.12), RGBA(240, 112, 90, 0.14))
        }
    }

    static func layer(_ layer: StrataLayer, _ a: ADKAppearance) -> RGBA {
        switch layer {
        case .ai: pick(a, RGBA(hex: 0xD9733A), RGBA(hex: 0xF08A50))
        case .worktree: pick(a, RGBA(hex: 0x6B9B37), RGBA(hex: 0x8DBE55))
        case .build: pick(a, RGBA(hex: 0xC9A22A), RGBA(hex: 0xE2BC45))
        case .model: pick(a, RGBA(hex: 0x3D6ED6), RGBA(hex: 0x6A93F0))
        case .docker: pick(a, RGBA(hex: 0x3E93B5), RGBA(hex: 0x5CB2D4))
        case .junk: pick(a, RGBA(hex: 0xB4615A), RGBA(hex: 0xD07D75))
        case .apps: pick(a, RGBA(hex: 0x8E5CA8), RGBA(hex: 0xB07FCB))
        case .media: pick(a, RGBA(hex: 0x5E8E86), RGBA(hex: 0x7DB0A7))
        case .other: pick(a, RGBA(hex: 0xA9ABB2), RGBA(hex: 0x5C616C))
        }
    }

    /// Sequential teal → stone ramp for file age (newest first), light / dark.
    static func age(_ step: Int, _ a: ADKAppearance) -> RGBA {
        let light: [UInt32] = [0x0B847B, 0x3F9E94, 0x7DB8AE, 0xB3BEB6, 0xC8C6C0, 0xDAD7D1]
        let dark: [UInt32] = [0x3DCBBE, 0x63B9AE, 0x86A8A0, 0x8F9894, 0x6E727B, 0x454A54]
        let i = min(max(step, 0), 5)
        return RGBA(hex: a.isDark ? dark[i] : light[i])
    }
}
