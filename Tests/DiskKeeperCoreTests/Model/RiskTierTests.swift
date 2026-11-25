import XCTest
@testable import DiskKeeperCore

final class RiskTierTests: XCTestCase {
    func testOrderingIsSafeReviewKeep() {
        XCTAssertTrue(RiskTier.safe < .review)
        XCTAssertTrue(RiskTier.review < .keep)
        XCTAssertEqual(RiskTier.allCases.sorted(), [.safe, .review, .keep])
    }

    func testRawValuesMatchRuleJSON() {
        XCTAssertEqual(RiskTier.allCases.map(\.rawValue), ["safe", "review", "keep"])
    }

    func testDecodingUnknownTierThrows() {
        XCTAssertThrowsError(try decodeJSON(RiskTier.self, "\"dangerous\""))
    }

    func testEscalatedNeverLowers() {
        for a in RiskTier.allCases {
            for b in RiskTier.allCases {
                XCTAssertEqual(a.escalated(to: b), max(a, b))
            }
        }
        XCTAssertEqual(RiskTier.keep.escalated(to: .safe), .keep)
    }

    func testSelectability() {
        XCTAssertFalse(RiskTier.keep.isSelectable)
        XCTAssertTrue(RiskTier.safe.isSelectable)
        XCTAssertTrue(RiskTier.review.isSelectable)
        XCTAssertTrue(RiskTier.safe.isBulkSelectable)
        XCTAssertFalse(RiskTier.review.isBulkSelectable)
        XCTAssertFalse(RiskTier.keep.isBulkSelectable)
    }
}
