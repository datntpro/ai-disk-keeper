import XCTest
@testable import DiskKeeperCore

final class SizeCacheInvalidationTests: XCTestCase {
    private var fx: FixtureHome!
    private var journal: FakeJournal!
    private var cacheFile: URL!

    override func setUpWithError() throws {
        fx = try FixtureHome()
        journal = FakeJournal()
        cacheFile = URL(fileURLWithPath: fx.tempDir + "/size-cache.json")
        try fx.file("home/a/deep/er/x.bin", bytes: 4096)
        try fx.file("home/a/y.bin", bytes: 4096)
        try fx.file("home/b/z.bin", bytes: 4096)
    }

    private func cache() -> SizeCache { SizeCache(fileURL: cacheFile, journal: journal) }
    private func url(_ rel: String) -> URL { URL(fileURLWithPath: fx.abs(rel)) }

    /// Scan 1 populates a/ and b/ and persists; returns after `endScan`.
    private func warm() async throws {
        let c = cache()
        let ctx = try makeContext(fx, cache: c)
        await c.beginScan(options: ctx.sizerOptions)
        _ = try await ctx.size(url("home/a")); _ = try await ctx.size(url("home/b"))
        await c.endScan()
    }

    /// Scan 2 with a fresh cache instance (loads the file): which of a/, b/ were served from the cache.
    private func second() async throws -> (a: Bool, b: Bool) {
        let c = cache()
        let ctx = try makeContext(fx, cache: c)
        await c.beginScan(options: ctx.sizerOptions)
        let a = await c.valid(url("home/a")) != nil
        let b = await c.valid(url("home/b")) != nil
        return (a, b)
    }

    func testNothingChangedKeepsEverything() async throws {
        try await warm()
        let r = try await second()
        XCTAssertTrue(r.a); XCTAssertTrue(r.b)
        XCTAssertEqual(journal.sinceRequests, [100])
    }

    func testFileAddedDeepInTreeInvalidatesOnlyThatItem() async throws {
        try await warm()
        journal.result = .changed([fx.abs("home/a/deep/er/new.bin")])
        let r = try await second()
        XCTAssertFalse(r.a); XCTAssertTrue(r.b)
    }

    func testChangeToTheRootItselfInvalidates() async throws {
        try await warm()
        journal.result = .changed([fx.abs("home/b")])
        let r = try await second()
        XCTAssertTrue(r.a); XCTAssertFalse(r.b)
    }

    func testChangeInAnAncestorDirectoryInvalidates() async throws {
        try await warm()
        journal.result = .changed([fx.abs("home")])
        let r = try await second()
        XCTAssertFalse(r.a); XCTAssertFalse(r.b)
    }

    func testChangeInSiblingTreeKeepsTheOthers() async throws {
        try await warm()
        journal.result = .changed([fx.abs("home/c/other.bin"), fx.abs("home/ab/x")])   // "ab" is not inside "a"
        let r = try await second()
        XCTAssertTrue(r.a); XCTAssertTrue(r.b)
    }

    func testJournalGapInvalidatesEverything() async throws {
        try await warm()
        journal.result = .invalidateAll   // MustScanSubDirs, UserDropped, KernelDropped, wrap, timeout…
        let r = try await second()
        XCTAssertFalse(r.a); XCTAssertFalse(r.b)
    }

    func testUUIDMismatchInvalidatesEverything() async throws {
        try await warm()
        journal.uuid = "UUID-B"
        let r = try await second()
        XCTAssertFalse(r.a); XCTAssertFalse(r.b)
    }

    func testMissingUUIDInvalidatesEverything() async throws {
        try await warm()
        journal.uuid = nil
        let r = try await second()
        XCTAssertFalse(r.a); XCTAssertFalse(r.b)
    }

    func testAppBuildChangeInvalidatesEverything() async throws {
        try await warm()
        let c = SizeCache(fileURL: cacheFile, journal: journal, appBuild: "other-build")
        await c.beginScan(options: .init())
        let a = await c.valid(url("home/a"))
        XCTAssertNil(a)
    }

    func testSizerOptionsChangeInvalidatesEverything() async throws {
        try await warm()
        let c = cache()
        await c.beginScan(options: FileSizer.Options(crossVolumes: true))
        let a = await c.valid(url("home/a"))
        XCTAssertNil(a)
    }

    func testRootReplacedWithNewInodeInvalidates() async throws {
        try await warm()
        let a = fx.abs("home/a")
        try FileManager.default.removeItem(atPath: a)
        try fx.file("home/a/y.bin", bytes: 4096)   // same path, new directory inode, journal says nothing
        let r = try await second()
        XCTAssertFalse(r.a); XCTAssertTrue(r.b)
    }

    func testEventIDIsCapturedBeforeTheJournalIsAsked() async throws {
        try await warm()
        journal.id = 555
        let c = cache()
        await c.beginScan(options: .init())
        await c.endScan()
        let c2 = cache()
        journal.id = 900
        await c2.beginScan(options: .init())
        XCTAssertEqual(journal.sinceRequests.last, 555)   // the next scan starts where the last one began
    }

    func testIncompleteReportsAreNeverCached() async throws {
        let c = cache()
        let ctx = try makeContext(fx, cache: c)
        await c.beginScan(options: ctx.sizerOptions)
        let u = url("home/b")
        let stamp = await c.stamp(u)
        var report = SizeReport(allocatedBytes: 1)
        report.issueCount = 1
        await c.store(report, for: u, stamp: stamp)
        let n = await c.count
        XCTAssertEqual(n, 0)
    }

    func testLookupBeforeBeginScanMisses() async throws {
        let c = cache()
        let stamp = await c.stamp(url("home/a"))
        XCTAssertNil(stamp)
    }

    func testCapacityEvictsLeastRecentlyUsed() async throws {
        let c = SizeCache(fileURL: nil, journal: journal, capacity: 1)
        let ctx = try makeContext(fx, cache: c)
        await c.beginScan(options: ctx.sizerOptions)
        _ = try await ctx.size(url("home/a")); _ = try await ctx.size(url("home/b"))
        await c.endScan()
        let n = await c.count
        XCTAssertEqual(n, 1)
    }

    // MARK: persistence

    func testCorruptFileIsIgnoredAndReplaced() async throws {
        try Data("{not json".utf8).write(to: cacheFile)
        let c = cache()
        let ctx = try makeContext(fx, cache: c)
        await c.beginScan(options: ctx.sizerOptions)
        let miss = await c.valid(url("home/a"))
        XCTAssertNil(miss)
        _ = try await ctx.size(url("home/a"))
        await c.endScan()
        let c2 = cache()
        await c2.beginScan(options: .init())
        let a = await c2.valid(url("home/a"))
        XCTAssertNotNil(a)
    }

    func testFileIsPrivate() async throws {
        try await warm()
        var st = stat()
        XCTAssertEqual(stat(cacheFile.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    func testClearRemovesEntriesAndFile() async throws {
        try await warm()
        let c = cache()
        await c.beginScan(options: .init())
        await c.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
        let a = await c.valid(url("home/a"))
        XCTAssertNil(a)
    }
}

// MARK: mid-scan writes, superseded scans, tampered files (PR #144 review)

extension SizeCacheInvalidationTests {
    /// The 6/15 race, deterministically: the write is not in the history query at `beginScan` but the live watch
    /// reports it before the item is looked up. The stale entry must not be served.
    func testWriteDeliveredAfterBeginScanIsNotServedStale() async throws {
        try await warm()
        let c = cache()
        let ctx = try makeContext(fx, cache: c)
        await c.beginScan(options: ctx.sizerOptions)          // history says: nothing changed
        journal.injectLive([fx.abs("home/a/deep/er/x.bin")])  // …but x.bin was written; delivered late
        let a = await c.valid(url("home/a"))
        let b = await c.valid(url("home/b"))
        XCTAssertNil(a, "stale report served for a path written during the scan")
        XCTAssertNotNil(b)
    }

    func testWriteDuringTheWalkIsNotStored() async throws {
        let c = cache()
        let ctx = try makeContext(fx, cache: c)
        await c.beginScan(options: ctx.sizerOptions)
        let u = url("home/a")
        let stamp = await c.stamp(u)
        let report = try await FileSizer().size(of: u)
        journal.injectLive([fx.abs("home/a/y.bin")])          // written while/after the walk read it
        await c.store(report, for: u, stamp: stamp)
        let n = await c.count
        XCTAssertEqual(n, 0)
    }

    func testLostWatchDropsEverythingAndStopsCaching() async throws {
        try await warm()
        let c = cache()
        let ctx = try makeContext(fx, cache: c)
        await c.beginScan(options: ctx.sizerOptions)
        journal.loseWatch()
        let a = await c.valid(url("home/a"))
        XCTAssertNil(a)
        let stamp = await c.stamp(url("home/b"))
        XCTAssertNil(stamp)
    }

    func testNoWatchMeansNoCache() async throws {
        try await warm()
        journal.noWatch = true
        let c = cache()
        await c.beginScan(options: .init())
        let a = await c.valid(url("home/a"))
        XCTAssertNil(a)
    }

    func testStoreFromSupersededScanIsRejected() async throws {
        let c = SizeCache(fileURL: nil, journal: journal)
        let ctx = try makeContext(fx, cache: c)
        await c.beginScan(options: ctx.sizerOptions)                  // scan 1
        let u = url("home/a")
        let stamp = await c.stamp(u)
        let stale = try await FileSizer().size(of: u)
        try FileHandle(forWritingTo: URL(fileURLWithPath: fx.abs("home/a/y.bin"))).append(1 << 16)
        journal.id = 200; journal.result = .changed([fx.abs("home/a/y.bin")])
        await c.beginScan(options: ctx.sizerOptions)                  // scan 2 consumes the write
        await c.store(stale, for: u, stamp: stamp)                    // scan 1's late store
        journal.id = 300; journal.result = .changed([])
        await c.beginScan(options: ctx.sizerOptions)                  // scan 3
        let hit = await c.valid(u)
        XCTAssertNil(hit)
    }

    func testFutureLastEventIDInvalidatesEverything() async throws {
        try await warm()
        journal.id = 50    // the saved id (100) is ahead of the journal's current id
        let r = try await second()
        XCTAssertFalse(r.a); XCTAssertFalse(r.b)
    }

    func testCacheFileWritableByOthersIsIgnored() async throws {
        try await warm()
        chmod(cacheFile.path, 0o666)
        let r = try await second()
        XCTAssertFalse(r.a); XCTAssertFalse(r.b)
    }
}

private extension FileHandle {
    func append(_ n: Int) throws { try seekToEnd(); try write(contentsOf: Data(repeating: 0x41, count: n)); try close() }
}
