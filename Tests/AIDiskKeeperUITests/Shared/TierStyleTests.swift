import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

final class TierStyleTests: XCTestCase {
    func testEveryTierHasCopyAndIcon() {
        for tier in RiskTier.allCases {
            let s = TierStyle.style(for: tier)
            XCTAssertEqual(s.tier, tier)
            XCTAssertFalse(s.label.isEmpty)
            XCTAssertFalse(s.symbolName.isEmpty)
            XCTAssertFalse(s.shortExplanation.isEmpty)
            XCTAssertFalse(s.longExplanation.isEmpty)
        }
    }

    func testSymbolsMatchGlyphsAndKeepIsNotSecondary() {
        XCTAssertEqual(TierStyle.style(for: .safe).symbolName, "circle.fill")
        XCTAssertEqual(TierStyle.style(for: .review).symbolName, "diamond.fill")
        XCTAssertEqual(TierStyle.style(for: .keep).symbolName, "circle")
        XCTAssertEqual(TierStyle.style(for: .safe).glyph, .safe)
        XCTAssertEqual(TierStyle.style(for: .review).glyph, .review)
        XCTAssertEqual(TierStyle.style(for: .keep).glyph, .keep)
        XCTAssertNotEqual(TierStyle.style(for: .keep).color, Color.secondary)
    }
}
