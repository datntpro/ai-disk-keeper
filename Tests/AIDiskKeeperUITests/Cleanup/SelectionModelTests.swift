import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

func makeItem(_ name: String, tier: RiskTier = .safe, category: ItemCategory = .aiToolData,
              tool: ToolID = .claudeCode, method: CleanupMethod = .trash, bytes: Int64 = 100) -> ScanItem {
    ScanItem(url: URL(fileURLWithPath: "/tmp/fake/\(name)"), displayName: name, tool: tool, category: category,
             sizeAllocated: bytes, sizeLogical: bytes, fileCount: 1, lastModified: nil, tier: tier,
             explanation: "x", ruleID: "r.\(name)", cleanupMethod: method)
}

@MainActor
final class SelectionModelTests: XCTestCase {
    func testKeepAndReportOnlyAreIgnored() {
        let s = SelectionModel()
        let keep = makeItem("k", tier: .keep), report = makeItem("r", method: .none)
        s.toggle(keep); s.toggle(report)
        s.setSelected(keep, true)
        XCTAssertTrue(s.selectedIDs.isEmpty)
    }

    func testReviewTogglesButIsNeverBulkSelected() {
        let s = SelectionModel()
        let review = makeItem("rv", tier: .review), safe = makeItem("s"),
            model = makeItem("m", category: .modelWeights), keep = makeItem("k", tier: .keep)
        s.toggle(review)
        XCTAssertEqual(s.selectedIDs, [review.id])
        s.deselectAll()
        s.selectAllSafe(in: [review, safe, model, keep])
        XCTAssertEqual(s.selectedIDs, [safe.id])
    }

    func testSelectAllSafeRespectsScope() {
        let s = SelectionModel()
        let a = makeItem("a", tool: .claudeCode), b = makeItem("b", tool: .cursor)
        s.selectAllSafe(in: [a])
        XCTAssertEqual(s.selectedIDs, [a.id])
        XCTAssertFalse(s.selectedIDs.contains(b.id))
    }

    func testStaleIDsDroppedAndSummary() {
        let s = SelectionModel()
        let a = makeItem("a", bytes: 10), r = makeItem("r", tier: .review, bytes: 5), gone = makeItem("g")
        s.toggle(a); s.toggle(r); s.toggle(gone)
        let current = [a, r]
        XCTAssertEqual(s.selectedItems(in: current).map(\.id), [a.id, r.id])
        let sum = s.summary(in: current)
        XCTAssertEqual(sum.count, 2)
        XCTAssertEqual(sum.bytes, 15)
        XCTAssertEqual(sum.reviewCount, 1)
    }

    func testToggleTwiceDeselects() {
        let s = SelectionModel(); let a = makeItem("a")
        s.toggle(a); s.toggle(a)
        XCTAssertTrue(s.selectedIDs.isEmpty)
    }

    func testSelectionClearsWhenScanGenerationChanges() {
        let s = SelectionModel(); let a = makeItem("a")
        s.syncScanGeneration(1)
        s.toggle(a)
        s.syncScanGeneration(1)
        XCTAssertEqual(s.selectedIDs, [a.id])
        s.syncScanGeneration(2)
        XCTAssertTrue(s.selectedIDs.isEmpty)
    }
}
