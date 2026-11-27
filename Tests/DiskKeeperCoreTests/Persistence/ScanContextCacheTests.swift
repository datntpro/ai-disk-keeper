import XCTest
@testable import DiskKeeperCore

final class ScanContextCacheTests: XCTestCase {
    private var fx: FixtureHome!
    override func setUpWithError() throws { fx = try FixtureHome() }

    private func url(_ rel: String) -> URL { URL(fileURLWithPath: fx.abs(rel)) }

    func testMissSizesAndStoresThenHitReturnsCachedReport() async throws {
        try fx.file("home/t/x", bytes: 5000)
        let cache = SizeCache(fileURL: nil, journal: FakeJournal())
        let ctx = try makeContext(fx, cache: cache)
        await cache.beginScan(options: ctx.sizerOptions)
        let first = try await ctx.size(url("home/t"))
        var hits = await cache.hits
        XCTAssertEqual(hits, 0)
        let second = try await ctx.size(url("home/t"))
        hits = await cache.hits
        XCTAssertEqual(hits, 1)
        XCTAssertEqual(first, second)
    }

    func testNoCacheMeansNoCaching() async throws {
        try fx.file("home/t/x", bytes: 5000)
        let ctx = try makeContext(fx, cache: nil)
        let r = try await ctx.size(url("home/t"))
        XCTAssertEqual(r.fileCount, 1)
    }

    /// End to end with the REAL journal: an in-place append changes no directory mtime, yet the next scan must
    /// re-size, see the new mtime and make a "newer than 1 day → keep" rule say Keep.
    func testInPlaceAppendMakesNextScanKeep() async throws {
        let old = Date().addingTimeInterval(-100 * 86_400)
        let file = try fx.file(".t/c/log.txt", bytes: 1000, modified: old)
        try fx.dir(".t/c", modified: old)
        guard SizeCache.dataVolumeDevice() != nil else { throw XCTSkip("no Data volume") }
        let rules = RuleFixtures.file(tool: "t", rules: [RuleFixtures.rule(
            id: "t.r", paths: #"["~/.t/c"]"#, match: #"{"kind":"self"}"#, tier: "safe",
            extra: #""tierWhen":[{"if":{"newerThanDays":1},"tier":"keep"}]"#)])
        let loaded = try RuleHarness.loadRules(json: rules, fixture: fx)
        let cacheFile = URL(fileURLWithPath: fx.tempDir + "/size-cache.json")

        var lastCache: SizeCache?
        func scan() async throws -> ScanItem? {
            try await Task.sleep(for: .seconds(2))           // let fseventsd assign ids to earlier writes
            let cache = SizeCache(fileURL: cacheFile)        // real journal
            lastCache = cache
            let ctx = ScanContext(environment: fx.env,
                                  pathGuard: try ScanGuard(environment: fx.env, protectPatterns: loaded.protectPatterns),
                                  sizeCache: cache)
            await cache.beginScan(options: ctx.sizerOptions)
            let box = ItemBox()
            let sink = ScanSink(item: { await box.add($0) }, warning: { _ in }, progress: { _ in })
            try await RuleScanner(rules: loaded.allRules).scan(context: ctx, sink: sink)
            await cache.endScan()
            return await box.items.first
        }

        let first = try await scan()
        XCTAssertEqual(first?.tier, .safe)
        let second = try await scan()          // warm, nothing changed: from the cache
        XCTAssertEqual(second?.tier, .safe)
        let secondHits = await lastCache?.hits
        XCTAssertEqual(secondHits, 1, "the warm scan must really be served from the cache, or this test proves nothing")

        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: file))       // append in place: no directory mtime changes
        try h.seekToEnd(); try h.write(contentsOf: Data("more".utf8)); try h.close()
        var st = stat(); XCTAssertEqual(stat(fx.abs(".t/c"), &st), 0)
        XCTAssertEqual(Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)).timeIntervalSince(old), 0, accuracy: 1,
                       "precondition: the directory mtime did not move")

        let third = try await scan()
        XCTAssertEqual(third?.tier, .keep, "stale cache made freshly written data look Safe")
    }

    private actor ItemBox { var items: [ScanItem] = []; func add(_ i: ScanItem) { items.append(i) } }
}
