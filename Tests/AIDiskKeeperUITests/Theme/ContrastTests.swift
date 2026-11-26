import XCTest
@testable import AIDiskKeeperUI

final class ContrastTests: XCTestCase {
    private func solid(_ c: ADKColor, _ a: ADKAppearance) -> RGBA { c.rgba(a) }

    func testTierInkOnSoftFillMeetsAA() {
        let tiers: [(ink: ADKColor, soft: ADKColor)] = [
            (.safeInk, .safeSoft), (.reviewInk, .reviewSoft), (.keepInk, .keepSoft), (.dangerInk, .dangerSoft),
        ]
        for a in ADKAppearance.allCases {
            for t in tiers {
                for under in [ADKColor.surface, .bg] {
                    let fill = composite(t.soft.rgba(a), over: under.rgba(a))
                    let r = contrastRatio(t.ink.rgba(a), fill)
                    XCTAssertGreaterThanOrEqual(r, 4.5, "\(t.ink) on \(t.soft) over \(under), \(a): \(r)")
                }
            }
        }
    }

    func testTextTokens() {
        for a in ADKAppearance.allCases {
            for under in [ADKColor.surface, .bg] {
                let bg = under.rgba(a)
                XCTAssertGreaterThanOrEqual(contrastRatio(ADKColor.text.rgba(a), bg), 4.5, "text \(a)")
                XCTAssertGreaterThanOrEqual(contrastRatio(ADKColor.text2.rgba(a), bg), 4.5, "text2 \(a)")
                XCTAssertGreaterThanOrEqual(contrastRatio(ADKColor.text3.rgba(a), bg), 3.0, "text3 \(a)")
            }
        }
    }

    func testHighContrastInkIsPinned() {
        // Light HC: dark ink on Safe/Review, white on Keep/Danger. Dark HC: near-black on all.
        let expectLight: [(ADKColor, UInt32)] = [(.safeInk, 0x0C0E12), (.reviewInk, 0x0C0E12), (.keepInk, 0xFFFFFF), (.dangerInk, 0xFFFFFF)]
        for (c, hex) in expectLight { XCTAssertEqual(c.rgba(.highContrastLight), RGBA(hex: hex), "\(c)") }
        for c in [ADKColor.safeInk, .reviewInk, .keepInk, .dangerInk] {
            XCTAssertEqual(c.rgba(.highContrastDark), RGBA(hex: 0x0C0E12), "\(c)")
        }
    }

    func testSoftIsSolidInHighContrast() {
        for a in [ADKAppearance.highContrastLight, .highContrastDark] {
            XCTAssertEqual(ADKColor.safeSoft.rgba(a), ADKColor.safe.rgba(a))
            XCTAssertEqual(ADKColor.line.rgba(a), ADKColor.lineStrong.rgba(a))
        }
    }

    func testLabelInkPicksPassingColour() {
        let ink = labelInk(onFill: ADKColor.safe.rgba(.light), appearance: .light)
        XCTAssertEqual(ink, .text)
        XCTAssertEqual(labelInk(onFill: ADKColor.keep.rgba(.light), appearance: .light), .onAccent)
    }

    func testOnAccentLabelOnAccentFillMeetsAA() {
        for a in ADKAppearance.allCases {
            let r = contrastRatio(ADKColor.onAccent.rgba(a), ADKColor.accent.rgba(a))
            XCTAssertGreaterThanOrEqual(r, 4.5, "onAccent on accent, \(a): \(r)")
        }
    }

    func testHatchStaysInsideItsFrame() {
        let rect = CGRect(x: 10, y: 20, width: 50, height: 30)
        let b = HatchPattern.path(in: rect).boundingRect
        XCTAssertGreaterThanOrEqual(b.minX, rect.minX - 0.001)
        XCTAssertLessThanOrEqual(b.maxX, rect.maxX + 0.001)
        XCTAssertGreaterThanOrEqual(b.minY, rect.minY - 0.001)
        XCTAssertLessThanOrEqual(b.maxY, rect.maxY + 0.001)
        XCTAssertFalse(HatchPattern.path(in: rect).isEmpty)
    }

    func testContrastMath() {
        XCTAssertEqual(contrastRatio(RGBA(hex: 0x000000), RGBA(hex: 0xFFFFFF)), 21, accuracy: 0.01)
        let c = composite(RGBA(0, 0, 0, 0.5), over: RGBA(hex: 0xFFFFFF))
        XCTAssertEqual(c.r, 0.5, accuracy: 0.001)
    }
}
