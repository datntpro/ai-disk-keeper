import XCTest
@testable import DiskKeeperCore

final class ScanResultTests: XCTestCase {
    private let pA = ProjectRef(id: "/p/a", displayName: "a")
    private let pB = ProjectRef(id: "/p/b", displayName: "b")

    private func result(_ items: [ScanItem]) -> ScanResult {
        ScanResult(items: items, startedAt: ModelFixtures.date)
    }

    private func varied() -> [ScanItem] {
        typealias F = ModelFixtures
        return [
            F.item(path: "/1", tier: .safe, tool: .claudeCode, category: .aiToolData, project: pA, allocated: 10, logical: 9, files: 1),
            F.item(path: "/2", tier: .safe, tool: .claudeCode, category: .buildArtifact, project: pA, allocated: 20, logical: 19, files: 2),
            F.item(path: "/3", tier: .review, tool: .cursor, category: .aiToolData, project: pA, allocated: 30, logical: 29, files: 3),
            F.item(path: "/4", tier: .keep, tool: .git, category: .worktree, project: pB, allocated: 40, logical: 39, files: 4),
            F.item(path: "/5", tier: .safe, tool: .ollama, category: .modelWeights, allocated: 50, logical: 49, files: 5),
            F.item(path: "/6", tier: .review, tool: .docker, category: .docker, allocated: 60, logical: 59, files: 6, cleanup: .none),
            F.item(path: "/7", tier: .safe, tool: .system, category: .systemJunk, allocated: 70, logical: 69, files: 7),
            F.item(path: "/8", tier: .safe, tool: .system, category: .systemJunk, project: pB, allocated: 80, logical: 79, files: 8),
            F.item(path: "/9", tier: .review, tool: .cursor, category: .aiToolData, allocated: 90, logical: 89, files: 9),
            F.item(path: "/10", tier: .keep, tool: .codex, category: .aiToolData, allocated: 100, logical: 99, files: 10),
            F.item(path: "/11", tier: .safe, tool: .codex, category: .aiToolData, allocated: 110, logical: 109, files: 11),
            F.item(path: "/12", tier: .review, tool: .claudeCode, category: .worktree, allocated: 120, logical: 119, files: 12),
        ]
    }

    func testEmptyResult() {
        let r = result([])
        XCTAssertEqual(r.total, .zero)
        XCTAssertEqual(r.totalsByTier.count, 3)
        XCTAssertTrue(r.totalsByTier.values.allSatisfy { $0 == .zero })
        XCTAssertTrue(r.totalsByCategory.isEmpty)
        XCTAssertTrue(r.totalsByTool.isEmpty)
        XCTAssertTrue(r.totalsByProject.isEmpty)
        XCTAssertEqual(r.topItems(limit: 5), [])
    }

    func testTotalsByTier() {
        let t = result(varied()).totalsByTier
        XCTAssertEqual(t[.safe], UsageTotals(itemCount: 6, allocatedBytes: 340, logicalBytes: 334, fileCount: 34))
        XCTAssertEqual(t[.review], UsageTotals(itemCount: 4, allocatedBytes: 300, logicalBytes: 296, fileCount: 30))
        XCTAssertEqual(t[.keep], UsageTotals(itemCount: 2, allocatedBytes: 140, logicalBytes: 138, fileCount: 14))
    }

    func testTotalsByCategory() {
        let t = result(varied()).totalsByCategory
        XCTAssertEqual(t[.systemJunk], UsageTotals(itemCount: 2, allocatedBytes: 150, logicalBytes: 148, fileCount: 15))
        XCTAssertEqual(t[.docker], UsageTotals(itemCount: 1, allocatedBytes: 60, logicalBytes: 59, fileCount: 6))
        XCTAssertEqual(t[.worktree], UsageTotals(itemCount: 2, allocatedBytes: 160, logicalBytes: 158, fileCount: 16))
        XCTAssertEqual(t[.aiToolData], UsageTotals(itemCount: 5, allocatedBytes: 340, logicalBytes: 335, fileCount: 34))
        XCTAssertEqual(t[.buildArtifact]?.itemCount, 1)
        XCTAssertEqual(t.count, 6)
    }

    func testTotalsByTool() {
        let t = result(varied()).totalsByTool
        XCTAssertEqual(t[.claudeCode], UsageTotals(itemCount: 3, allocatedBytes: 150, logicalBytes: 147, fileCount: 15))
        XCTAssertEqual(t[.cursor], UsageTotals(itemCount: 2, allocatedBytes: 120, logicalBytes: 118, fileCount: 12))
        XCTAssertEqual(t[.codex], UsageTotals(itemCount: 2, allocatedBytes: 210, logicalBytes: 208, fileCount: 21))
        XCTAssertEqual(t[.system], UsageTotals(itemCount: 2, allocatedBytes: 150, logicalBytes: 148, fileCount: 15))
        XCTAssertEqual(t.count, 7)
    }

    func testTotalsByProjectAndUnattributed() {
        let items = [
            ModelFixtures.item(path: "/1", project: pA, allocated: 1),
            ModelFixtures.item(path: "/2", project: pA, allocated: 2),
            ModelFixtures.item(path: "/3", project: pA, allocated: 4),
            ModelFixtures.item(path: "/4", project: pB, allocated: 8),
            ModelFixtures.item(path: "/5", allocated: 16),
            ModelFixtures.item(path: "/6", allocated: 32),
        ]
        let r = result(items)
        XCTAssertEqual(r.totalsByProject[pA]?.itemCount, 3)
        XCTAssertEqual(r.totalsByProject[pA]?.allocatedBytes, 7)
        XCTAssertEqual(r.totalsByProject[pB]?.allocatedBytes, 8)
        XCTAssertEqual(r.unattributedTotals.itemCount, 2)
        XCTAssertEqual(r.unattributedTotals.allocatedBytes, 48)
    }

    func testProjectGroupingUsesIDOnly() {
        let items = [
            ModelFixtures.item(path: "/1", project: ProjectRef(id: "/p/a", displayName: "one")),
            ModelFixtures.item(path: "/2", project: ProjectRef(id: "/p/a", displayName: "two")),
        ]
        let r = result(items)
        XCTAssertEqual(r.totalsByProject.count, 1)
        XCTAssertEqual(r.totalsByProject.first?.key.displayName, "one")
        XCTAssertEqual(r.totalsByProject.first?.value.itemCount, 2)
    }

    func testEveryGroupingSumsToTotal() {
        let r = result(varied())
        let total = r.total
        XCTAssertEqual(total.itemCount, 12)
        XCTAssertEqual(r.totalsByTier.values.reduce(.zero, +), total)
        XCTAssertEqual(r.totalsByCategory.values.reduce(.zero, +), total)
        XCTAssertEqual(r.totalsByTool.values.reduce(.zero, +), total)
        XCTAssertEqual(r.totalsByProject.values.reduce(.zero, +) + r.unattributedTotals, total)
    }

    func testReclaimableExcludesKeepAndNonActionable() {
        let r = result(varied())
        // excludes keep (/4 40, /10 100) and non-actionable (/6 60)
        XCTAssertEqual(r.reclaimable.itemCount, 9)
        XCTAssertEqual(r.reclaimable.allocatedBytes, r.total.allocatedBytes - 40 - 100 - 60)
    }

    func testBulkReclaimableOnlySafeNonModel() {
        let r = result(varied())
        // safe, actionable, non-model: /1 /2 /7 /8 /11
        XCTAssertEqual(r.bulkReclaimable.itemCount, 5)
        XCTAssertEqual(r.bulkReclaimable.allocatedBytes, 10 + 20 + 70 + 80 + 110)
    }

    func testDuplicateIDsKeepFirst() throws {
        let a = ModelFixtures.item(path: "/x", allocated: 1)
        let b = ModelFixtures.item(path: "/x", allocated: 2)
        let r = result([a, b])
        XCTAssertEqual(r.items.count, 1)
        XCTAssertEqual(r.items[0].sizeAllocated, 1)

        // Decode a payload that contains duplicate ids.
        let one = try ModelFixtures.jsonString(a)
        let two = try ModelFixtures.jsonString(b)
        let json = "{\"items\":[\(one),\(two)],\"schemaVersion\":1,\"startedAt\":\"2026-11-01T10:00:00.000Z\",\"wasCancelled\":false}"
        let decoded = try ModelFixtures.decodeJSON(ScanResult.self, json)
        XCTAssertEqual(decoded.items.count, 1)
        XCTAssertEqual(decoded.items[0].sizeAllocated, 1)
    }

    func testTopItemsOrderAndTieBreak() {
        let items = [
            ModelFixtures.item(path: "/b", allocated: 5),
            ModelFixtures.item(path: "/a", allocated: 5),
            ModelFixtures.item(path: "/c", allocated: 9),
            ModelFixtures.item(path: "/d", allocated: 1),
        ]
        let r = result(items)
        XCTAssertEqual(r.topItems(limit: 3).map(\.path), ["/c", "/a", "/b"])
        XCTAssertEqual(r.topItems(limit: 100).count, 4)
        XCTAssertEqual(r.topItems(limit: 0), [])
        XCTAssertEqual(r.topItems(limit: -1), [])
    }

    func testRoundTripWithWarningsAndCancelled() throws {
        let r = ScanResult(
            items: varied(),
            warnings: [ScanWarning(kind: .permissionDenied, path: "/x", ruleID: "r", message: "m"),
                       ScanWarning(kind: .timeout, message: "slow")],
            startedAt: ModelFixtures.date,
            finishedAt: ModelFixtures.date.addingTimeInterval(5),
            wasCancelled: true)
        XCTAssertEqual(try ModelFixtures.roundTrip(r), r)
    }

    func testSchemaVersionEncodedAndFutureVersionRejected() throws {
        let r = result([])
        let s = try ModelFixtures.jsonString(r)
        XCTAssertTrue(s.contains("\"schemaVersion\":1"))
        let future = s.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        XCTAssertThrowsError(try ModelFixtures.decodeJSON(ScanResult.self, future))
    }
}
