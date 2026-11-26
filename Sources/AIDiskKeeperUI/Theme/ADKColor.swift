import AppKit
import SwiftUI

/// Every Strata colour token. Each resolves live against the view's appearance, including Increase Contrast.
enum ADKColor: CaseIterable, Sendable {
    case bg, surface, surface2, sunken, line, lineStrong, text, text2, text3
    case accent, accentHover, accentSoft, onAccent, focus
    case safe, safeInk, safeSoft, review, reviewInk, reviewSoft, keep, keepInk, keepSoft
    case danger, dangerInk, dangerSoft

    func rgba(_ appearance: ADKAppearance) -> RGBA { StrataPalette.rgba(self, appearance) }

    /// A dynamic colour: resolved per-appearance by AppKit each time it is drawn.
    var nsColor: NSColor {
        let token = self
        return NSColor(name: nil) { appearance in
            token.rgba(ADKAppearance(appearance)).nsColor
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}
