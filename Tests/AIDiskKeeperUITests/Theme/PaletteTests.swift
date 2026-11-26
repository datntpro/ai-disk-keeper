import AppKit
import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

final class PaletteTests: XCTestCase {
    func testEveryTokenDiffersBetweenLightAndDark() {
        // Tokens that intentionally share a value across modes are listed here.
        let same: Set<ADKColor> = []
        for c in ADKColor.allCases where !same.contains(c) {
            XCTAssertNotEqual(c.rgba(.light), c.rgba(.dark), "\(c)")
        }
        for l in StrataLayer.allCases { XCTAssertNotEqual(l.rgba(.light), l.rgba(.dark), "\(l)") }
    }

    func testLayerMappingCoversEveryCategory() {
        for c in ItemCategory.allCases { _ = StrataLayer(category: c) }
        XCTAssertEqual(StrataLayer(category: nil), .other)
        XCTAssertEqual(StrataLayer(category: .systemJunk), .junk)
        XCTAssertEqual(StrataLayer(category: .appLeftover), .apps)
        XCTAssertEqual(StrataLayer(category: .duplicate), .media)
    }

    func testAppearanceResolution() {
        XCTAssertEqual(ADKAppearance(NSAppearance(named: .aqua)!), .light)
        XCTAssertEqual(ADKAppearance(NSAppearance(named: .darkAqua)!), .dark)
        XCTAssertEqual(ADKAppearance(name: .accessibilityHighContrastAqua), .highContrastLight)
        XCTAssertEqual(ADKAppearance(name: .accessibilityHighContrastDarkAqua), .highContrastDark)
    }

    func testDynamicColourResolvesPerAppearance() {
        let c = ADKColor.bg.nsColor
        var light = RGBA(r: 0, g: 0, b: 0), dark = RGBA(r: 0, g: 0, b: 0)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let s = c.usingColorSpace(.sRGB)!; light = RGBA(r: s.redComponent, g: s.greenComponent, b: s.blueComponent)
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let s = c.usingColorSpace(.sRGB)!; dark = RGBA(r: s.redComponent, g: s.greenComponent, b: s.blueComponent)
        }
        XCTAssertEqual(light.r, ADKColor.bg.rgba(.light).r, accuracy: 0.005)
        XCTAssertEqual(dark.r, ADKColor.bg.rgba(.dark).r, accuracy: 0.005)
    }

    func testAgeRampHasDistinctStepsAndTitles() {
        for a in [ADKAppearance.light, .dark] {
            XCTAssertEqual(Set(AgeBucket.allCases.map { AgeRamp.rgba($0, a) }).count, AgeBucket.allCases.count)
        }
        for b in AgeBucket.allCases { XCTAssertFalse(AgeRamp.title(b).isEmpty) }
    }
}
