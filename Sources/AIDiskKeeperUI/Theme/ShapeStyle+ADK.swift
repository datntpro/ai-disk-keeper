import SwiftUI

/// `.adkAccent`, `.adkSafeInk`, … so call sites read like system styles.
extension ShapeStyle where Self == Color {
    static var adkBg: Color { ADKColor.bg.color }
    static var adkSurface: Color { ADKColor.surface.color }
    static var adkSurface2: Color { ADKColor.surface2.color }
    static var adkSunken: Color { ADKColor.sunken.color }
    static var adkLine: Color { ADKColor.line.color }
    static var adkLineStrong: Color { ADKColor.lineStrong.color }
    static var adkText: Color { ADKColor.text.color }
    static var adkText2: Color { ADKColor.text2.color }
    static var adkText3: Color { ADKColor.text3.color }
    static var adkAccent: Color { ADKColor.accent.color }
    static var adkAccentHover: Color { ADKColor.accentHover.color }
    static var adkAccentSoft: Color { ADKColor.accentSoft.color }
    static var adkOnAccent: Color { ADKColor.onAccent.color }
    static var adkFocus: Color { ADKColor.focus.color }
    static var adkSafe: Color { ADKColor.safe.color }
    static var adkSafeInk: Color { ADKColor.safeInk.color }
    static var adkSafeSoft: Color { ADKColor.safeSoft.color }
    static var adkReview: Color { ADKColor.review.color }
    static var adkReviewInk: Color { ADKColor.reviewInk.color }
    static var adkReviewSoft: Color { ADKColor.reviewSoft.color }
    static var adkKeep: Color { ADKColor.keep.color }
    static var adkKeepInk: Color { ADKColor.keepInk.color }
    static var adkKeepSoft: Color { ADKColor.keepSoft.color }
    static var adkDanger: Color { ADKColor.danger.color }
    static var adkDangerInk: Color { ADKColor.dangerInk.color }
    static var adkDangerSoft: Color { ADKColor.dangerSoft.color }
}
