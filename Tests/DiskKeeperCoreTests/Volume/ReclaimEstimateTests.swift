import XCTest
@testable import DiskKeeperCore

final class ReclaimEstimateTests: XCTestCase {
    private func item(_ n: String, allocated: Int64, reclaim: Int64? = nil, estimate: Bool = false) -> ScanItem {
        ScanItem(url: URL(fileURLWithPath: "/Users/t/\(n)"), displayName: n, tool: .claudeCode, category: .aiToolData,
                 sizeAllocated: allocated, sizeLogical: allocated, fileCount: 1, lastModified: nil, tier: .safe,
                 explanation: "e", ruleID: "r", reclaimableBytes: reclaim, reclaimIsEstimate: estimate)
    }

    func testPlainSelectionHasNoCaveats() {
        let e = ReclaimEstimate.make(items: [item("a", allocated: 100), item("b", allocated: 50, reclaim: 50)])
        XCTAssertEqual(e.shownBytes, 150)
        XCTAssertEqual(e.freesAboutBytes, 150)
        XCTAssertTrue(e.caveats.isEmpty)
        XCTAssertFalse(e.isMuchSmaller)
    }

    func testSharedBlocksLowerTheNumberAndAreExplained() {
        let e = ReclaimEstimate.make(items: [item("vm", allocated: 87_000, reclaim: 1_200)])
        XCTAssertEqual(e.freesAboutBytes, 1_200)
        XCTAssertEqual(e.caveats, [.clonesShared(bytes: 85_800)])
        XCTAssertTrue(e.isMuchSmaller)
    }

    func testCaveatsFromTrashSnapshotsAndUnknown() {
        let e = ReclaimEstimate.make(
            items: [item("a", allocated: 100, reclaim: 100, estimate: true), item("b", allocated: 10, reclaim: 10, estimate: true)],
            trashSameVolume: true, localSnapshotsPresent: true)
        XCTAssertEqual(e.caveats, [.trashSameVolume, .localSnapshotsPresent, .unknownForSome(count: 2)])
        XCTAssertTrue(e.hasUnknown)
        XCTAssertEqual(e.freesAboutBytes, 110)
    }

    func testNeverMoreThanShown() {
        let e = ReclaimEstimate(shownBytes: 10, freesAboutBytes: 99, caveats: [])
        XCTAssertEqual(e.freesAboutBytes, 10)
        let i = item("a", allocated: 10, reclaim: 99)
        XCTAssertEqual(i.reclaimableBytes, 10)
    }

    func testItemCodableRoundTripAndLegacyDecode() throws {
        let i = item("a", allocated: 100, reclaim: 40, estimate: true)
        let back = try JSONDecoder().decode(ScanItem.self, from: JSONEncoder().encode(i))
        XCTAssertEqual(back.reclaimableBytes, 40)
        XCTAssertTrue(back.reclaimIsEstimate)
        let legacy = try JSONDecoder().decode(ScanItem.self, from: JSONEncoder().encode(item("b", allocated: 5)))
        XCTAssertNil(legacy.reclaimableBytes)
    }

    func testScanContextProbesOnlyBigItems() async throws {
        let fx = try FixtureHome()
        try fx.file("home/big/a.bin", bytes: 3 * 1_048_576)
        try fx.file("home/small/a.bin", bytes: 1000)
        let ctx = ScanContext(environment: fx.env, pathGuard: try ScanGuard(environment: fx.env, protectPatterns: []),
                              reclaimProbeMinItemBytes: 1_000_000)
        let big = try await ctx.size(URL(fileURLWithPath: fx.abs("home/big")))
        let small = try await ctx.size(URL(fileURLWithPath: fx.abs("home/small")))
        XCTAssertNotNil(big.privateBytes)
        XCTAssertNil(small.privateBytes)
    }

    /// The cache keeps the new fields: a hit returns the probed report, not a re-walk without them.
    func testSizeCacheRoundTripKeepsPrivateFields() async throws {
        let fx = try FixtureHome()
        try fx.file("home/big/a.bin", bytes: 3 * 1_048_576)
        let cache = SizeCache(fileURL: nil, journal: FakeJournal())
        let ctx = ScanContext(environment: fx.env, pathGuard: try ScanGuard(environment: fx.env, protectPatterns: []),
                              sizeCache: cache, reclaimProbeMinItemBytes: 1_000_000)
        await cache.beginScan(options: ctx.sizerOptions)
        let first = try await ctx.size(URL(fileURLWithPath: fx.abs("home/big")))
        let second = try await ctx.size(URL(fileURLWithPath: fx.abs("home/big")))
        let hits = await cache.hits
        XCTAssertEqual(hits, 1)
        XCTAssertNotNil(second.privateBytes)
        XCTAssertEqual(first, second)
        let data = try JSONEncoder().encode(first)
        XCTAssertEqual(try JSONDecoder().decode(SizeReport.self, from: data), first)
        XCTAssertEqual(SizeCache.schemaVersion, 2)
    }
}
