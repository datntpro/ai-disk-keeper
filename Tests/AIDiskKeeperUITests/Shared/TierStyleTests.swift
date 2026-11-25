import DiskKeeperCore
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
}
