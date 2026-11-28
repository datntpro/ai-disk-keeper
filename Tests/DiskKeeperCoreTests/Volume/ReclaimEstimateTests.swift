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

    private func bigTree(_ fx: FixtureHome, bytes: Int = 4 * 1_048_576) throws {
        try fx.file("home/big/a.bin", bytes: bytes)
    }

    private func cachedContext(_ fx: FixtureHome, cache: SizeCache) throws -> ScanContext {
        ScanContext(environment: fx.env, pathGuard: try ScanGuard(environment: fx.env, protectPatterns: []),
                    sizeCache: cache, reclaimProbeMinItemBytes: 1_000_000)
    }

    /// B1: the cache stores the plain report only.
    func testCacheNeverStoresPrivateFields() {
        let r = SizeReport(allocatedBytes: 10, privateBytes: 5, sharedOutsideBytes: 5, probedBytes: 10, privateIsEstimate: true)
        let c = ScanContext.withoutReclaim(r)
        XCTAssertNil(c.privateBytes)
        XCTAssertEqual(c.sharedOutsideBytes, 0)
        XCTAssertEqual(c.probedBytes, 0)
        XCTAssertFalse(c.privateIsEstimate)
        XCTAssertEqual(c.allocatedBytes, 10)
    }

    /// B1: a clone made OUTSIDE the item after scan 1 (nothing changes inside it, so the cache hits) must not leave
    /// the old "frees everything" number.
    func testCloneMadeOutsideAfterFirstScanLowersFreesAbout() async throws {
        let fx = try FixtureHome()
        try bigTree(fx)
        let cache = SizeCache(fileURL: nil, journal: FakeJournal())
        let ctx = try cachedContext(fx, cache: cache)
        await cache.beginScan(options: ctx.sizerOptions)
        let first = try await ctx.size(URL(fileURLWithPath: fx.abs("home/big")))
        guard case .known = CloneProbe.probe(fx.abs("home/big/a.bin")) else { throw XCTSkip("volume does not report clone info") }
        XCTAssertGreaterThanOrEqual(first.privateBytes ?? 0, 4 * 1_048_576)
        try FileManager.default.createDirectory(atPath: fx.abs("home/elsewhere"), withIntermediateDirectories: true)
        if clonefile(fx.abs("home/big/a.bin"), fx.abs("home/elsewhere/copy.bin"), 0) != 0 { throw XCTSkip("no clonefile") }
        let second = try await ctx.size(URL(fileURLWithPath: fx.abs("home/big")))
        let hits = await cache.hits
        XCTAssertEqual(hits, 1, "the plain size comes from the cache")
        XCTAssertLessThan(second.privateBytes ?? .max, 1_048_576 / 2)
        XCTAssertEqual(second.allocatedBytes, first.allocatedBytes)
        // And the other way round: deleting the outside copy restores the full number on the next scan.
        try FileManager.default.removeItem(atPath: fx.abs("home/elsewhere/copy.bin"))
        let third = try await ctx.size(URL(fileURLWithPath: fx.abs("home/big")))
        XCTAssertGreaterThanOrEqual(third.privateBytes ?? 0, 4 * 1_048_576)
    }

    /// B1: a hard link added outside after scan 1 frees nothing.
    func testHardLinkMadeOutsideAfterFirstScanFreesNothing() async throws {
        let fx = try FixtureHome()
        try bigTree(fx)
        let cache = SizeCache(fileURL: nil, journal: FakeJournal())
        let ctx = try cachedContext(fx, cache: cache)
        await cache.beginScan(options: ctx.sizerOptions)
        _ = try await ctx.size(URL(fileURLWithPath: fx.abs("home/big")))
        XCTAssertEqual(link(fx.abs("home/big/a.bin"), fx.abs("home/outside-link.bin")), 0)
        let second = try await ctx.size(URL(fileURLWithPath: fx.abs("home/big")))
        XCTAssertEqual(second.externallyLinkedFileCount, 1)
        XCTAssertLessThan(second.privateBytes ?? .max, 1_048_576 / 2)
    }

    func testProbeFailureFallsBackToConservativeEstimate() {
        let r = ScanContext.conservative(SizeReport(allocatedBytes: 500))
        XCTAssertEqual(r.privateBytes, 500)
        XCTAssertTrue(r.privateIsEstimate)
        let (bytes, estimate) = ScanItem.reclaim(from: r)
        XCTAssertEqual(bytes, 500)
        XCTAssertTrue(estimate)
    }

    func testSizeReportRoundTrips() throws {
        let r = SizeReport(allocatedBytes: 9, privateBytes: 3, sharedOutsideBytes: 2, probedBytes: 7, privateIsEstimate: true)
        XCTAssertEqual(try JSONDecoder().decode(SizeReport.self, from: JSONEncoder().encode(r)), r)
        XCTAssertEqual(SizeCache.schemaVersion, 2)
    }

    func testSnapshotCaveatRules() {
        XCTAssertFalse(ReclaimEstimate.snapshotsMayHoldSpace(.listed([])))
        XCTAssertTrue(ReclaimEstimate.snapshotsMayHoldSpace(.listed([LocalSnapshot(name: "x", date: nil, kind: .timeMachine)])))
        XCTAssertTrue(ReclaimEstimate.snapshotsMayHoldSpace(.unavailable(.timedOut)))
    }

    func testTrashCaveatFollowsActionAndMethod() {
        let trashItem = item("a", allocated: 10)
        XCTAssertTrue(ReclaimEstimate.goesToTrash(.trash, trashItem))
        XCTAssertFalse(ReclaimEstimate.goesToTrash(.deletePermanently, trashItem))
        var other = item("b", allocated: 10)
        other.flags.insert(.otherVolume)
        XCTAssertTrue(ReclaimEstimate.goesToTrash(.trash, other))   // an external volume's Trash frees nothing either
        var tool = item("c", allocated: 10)
        tool.cleanupMethod = .toolCommand(command: "x", arguments: [])
        XCTAssertFalse(ReclaimEstimate.goesToTrash(.trash, tool))
    }

    func testCaveatsListUnknownOnlyOnce() {
        let e = ReclaimEstimate.make(items: [item("a", allocated: 100, reclaim: 100, estimate: true)])
        XCTAssertEqual(e.caveats, [.unknownForSome(count: 1)])
    }
}
