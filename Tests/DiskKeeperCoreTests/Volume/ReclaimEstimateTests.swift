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

    // MARK: F1: unmeasured items are not findings

    func testUnprobedBigItemIsUnknownAndNotMeasured() {
        let big = item("derived", allocated: 300_000_000)
        let e = ReclaimEstimate.make(items: [big])
        XCTAssertFalse(e.hasMeasured)
        XCTAssertFalse(e.isMuchSmaller)
        XCTAssertEqual(e.caveats, [.unknownForSome(count: 1)])
        let small = ReclaimEstimate.make(items: [item("tiny", allocated: 5_000_000)])
        XCTAssertFalse(small.hasMeasured)
        XCTAssertTrue(small.caveats.isEmpty)
    }

    func testEstimateItemsAreNotMeasured() {
        let e = ReclaimEstimate.make(items: [item("a", allocated: 100, reclaim: 100, estimate: true),
                                             item("b", allocated: 100, reclaim: 10)])
        XCTAssertEqual(e.measuredCount, 1)
        XCTAssertTrue(e.hasMeasured)
    }

    // MARK: F2: compressed files

    func testCompressedAndRefcountZeroAreConservative() {
        let zero = CloneInfo.known(cloneID: 0, refCount: 0, privateBytes: 0, sharesAllBlocks: false, maySharesBlocks: false)
        var r = FileSizer.privateBytes(zero, allocated: 5000, flags: 0)
        XCTAssertEqual(r.bytes, 5000); XCTAssertTrue(r.estimate)
        r = FileSizer.privateBytes(.known(cloneID: 7, refCount: 2, privateBytes: 0, sharesAllBlocks: true, maySharesBlocks: true),
                                   allocated: 5000, flags: 0)
        XCTAssertEqual(r.bytes, 0); XCTAssertFalse(r.estimate)        // a real fully shared clone really frees 0
        r = FileSizer.privateBytes(.known(cloneID: 7, refCount: 1, privateBytes: 10, sharesAllBlocks: false, maySharesBlocks: false),
                                   allocated: 5000, flags: FileSizer.ufCompressed)
        XCTAssertEqual(r.bytes, 5000); XCTAssertTrue(r.estimate)
    }

    func testRealCompressedFileIsAnEstimateNotZero() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        let src = try tmp.file("src.txt", contents: Data(repeating: 0x41, count: 4 * 1_048_576))
        let dst = tmp.url.appendingPathComponent("tree/c.txt")
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["--hfsCompression", "--noclone", src.path, dst.path]
        try p.run(); p.waitUntilExit()
        var st = stat()
        guard lstat(dst.path, &st) == 0, st.st_flags & FileSizer.ufCompressed != 0, st.st_blocks > 0 else {
            throw XCTSkip("could not make a compressed file here")
        }
        var o = FileSizer.Options(measurePrivateBytes: true, privateProbeMinFileSize: 1)
        o._cloneProbe = nil
        let r = try FileSizer(options: o).sizeBlocking(of: tmp.url.appendingPathComponent("tree"))
        XCTAssertGreaterThan(r.privateBytes ?? 0, 0)
        XCTAssertTrue(r.privateIsEstimate)
    }

    // MARK: F3: cheap refresh on a cache hit

    func testPlanRefreshSeesOutsideCloneAndLinkWithoutWalking() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        try tmp.file("tree/big.bin", bytes: 3 * 1_048_576)
        try tmp.file("tree/small.bin", bytes: 100)
        try tmp.hardlink("tree/small2.bin", to: "tree/small.bin")   // both names inside: a plan entry
        let walked = try FileSizer(options: .init(measurePrivateBytes: true)).sizeBlocking(of: tmp.url.appendingPathComponent("tree"))
        guard case .known = CloneProbe.probe(tmp.path("tree/big.bin")) else { throw XCTSkip("no clone info here") }
        XCTAssertNotNil(walked.reclaimPlan)
        let cached = ScanContext.cacheable(walked)
        XCTAssertNil(cached.privateBytes)
        XCTAssertNotNil(cached.reclaimPlan)
        let same = FileSizer.refreshReclaim(cached)
        XCTAssertEqual(same?.privateBytes, walked.privateBytes)

        // A clone and a hard link made outside the item after the walk.
        XCTAssertEqual(clonefile(tmp.path("tree/big.bin"), tmp.path("outside-clone.bin"), 0), 0)
        XCTAssertEqual(link(tmp.path("tree/small.bin"), tmp.path("outside-link.bin")), 0)
        let after = FileSizer.refreshReclaim(cached)
        XCTAssertNotNil(after)
        XCTAssertLessThan(after!.privateBytes!, walked.privateBytes! - Int64(2 * 1_048_576))
        XCTAssertEqual(after!.externallyLinkedFileCount, 1)
        XCTAssertGreaterThan(after!.sharedOutsideBytes, 0)
    }

    func testPlanRefreshGivesUpWhenAFileWasReplaced() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        try tmp.file("tree/big.bin", bytes: 2 * 1_048_576)
        let walked = try FileSizer(options: .init(measurePrivateBytes: true)).sizeBlocking(of: tmp.url.appendingPathComponent("tree"))
        try FileManager.default.removeItem(atPath: tmp.path("tree/big.bin"))
        try tmp.file("tree/big.bin", bytes: 2 * 1_048_576)
        XCTAssertNil(FileSizer.refreshReclaim(ScanContext.cacheable(walked)))
    }

    func testSmallFilesAreBaseBytesNotPlanEntries() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.cleanup() }
        for i in 0..<300 { try tmp.file("tree/f\(i).bin", bytes: 10) }
        // Every file is multi-link-free and tiny: they are base bytes, no entries, so a plan exists.
        let r = try FileSizer(options: .init(measurePrivateBytes: true)).sizeBlocking(of: tmp.url.appendingPathComponent("tree"))
        XCTAssertEqual(r.reclaimPlan?.entries.count, 0)
        XCTAssertGreaterThan(r.reclaimPlan?.baseBytes ?? 0, 0)
    }

    /// `ADK_BENCH=1`: cold scan without the probe, cold with it, and a warm cache hit (plan refresh).
    func testBenchmarkColdAndWarm() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ADK_BENCH"] == "1", "benchmark: set ADK_BENCH=1")
        let fx = try FixtureHome()
        for d in 0..<50 { for f in 0..<400 { _ = try fx.file("home/bench/d\(d)/f\(f).bin", bytes: 4096) } }
        for b in 0..<3 { _ = try fx.file("home/bench/big\(b).bin", bytes: 40 * 1_048_576) }
        let url = URL(fileURLWithPath: fx.abs("home/bench"))
        let guardd = try ScanGuard(environment: fx.env, protectPatterns: [])
        func time(_ f: () async throws -> Void) async rethrows -> Double {
            let t = Date(); try await f(); return Date().timeIntervalSince(t)
        }
        let plain = ScanContext(environment: fx.env, pathGuard: guardd, reclaimProbeMinItemBytes: nil)
        let coldPlain = try await time { _ = try await plain.size(url) }
        let cache = SizeCache(fileURL: nil, journal: FakeJournal())
        let probing = ScanContext(environment: fx.env, pathGuard: guardd, sizeCache: cache, reclaimProbeMinItemBytes: 1_000_000)
        await cache.beginScan(options: probing.sizerOptions)
        let coldProbe = try await time { _ = try await probing.size(url) }
        let warm = try await time { _ = try await probing.size(url) }
        let hits = await cache.hits
        print("H6 BENCH files=20003 cold-no-probe=\(coldPlain)s cold-probe=\(coldProbe)s warm-hit=\(warm)s hits=\(hits)")
        XCTAssertEqual(hits, 1)
    }
}
