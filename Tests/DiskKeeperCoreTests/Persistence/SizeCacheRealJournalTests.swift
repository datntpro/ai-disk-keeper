import Darwin
import XCTest
@testable import DiskKeeperCore

/// Adversarial tests for the T25 SizeCache (from the PR #144 review). Real FSEvents journal on temp dirs only.
/// Each test: warm the cache, mutate the tree in a way that changes no directory mtime where possible,
/// rescan with a fresh SizeCache instance (loads the file like a new process), assert the report is fresh.
final class SizeCacheRealJournalTests: XCTestCase {
    private var fx: FixtureHome!
    private var cacheFile: URL!
    override func setUpWithError() throws {
        guard SizeCache.dataVolumeDevice() != nil else { throw XCTSkip("no Data volume") }
        fx = try FixtureHome()
        cacheFile = URL(fileURLWithPath: fx.tempDir + "/size-cache.json")
    }
    private func url(_ rel: String) -> URL { URL(fileURLWithPath: fx.abs(rel)) }

    /// One scan of `rel` with a fresh cache loaded from disk. Returns the report and whether it was a hit.
    private func scan(_ rel: String, journal: any FSEventsJournaling = LiveFSEventsJournal(), settle: Bool = true) async throws -> (SizeReport, Bool) {
        if settle { try await Task.sleep(for: .seconds(2)) }   // let fseventsd assign ids to earlier writes (else spurious misses)
        let c = SizeCache(fileURL: cacheFile, journal: journal)
        let ctx = try makeContext(fx, cache: c)
        await c.beginScan(options: ctx.sizerOptions)
        let r = try await ctx.size(url(rel))
                await c.endScan()
        return (r, await c.hits == 1)
    }
    private func append(_ path: String, _ n: Int) throws {
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); try h.seekToEnd()
        try h.write(contentsOf: Data(repeating: 0x41, count: n)); try h.close()
    }
    private let old = Date().addingTimeInterval(-100 * 86_400)

    func testWarmScanIsAHit() async throws {
        try fx.file("home/item/f", bytes: 4096, modified: old)
        _ = try await scan("home/item")
        let (_, hit) = try await scan("home/item")
        XCTAssertTrue(hit, "untouched tree should be served from the cache (otherwise the attacks below prove nothing)")
    }

    /// Hard link: file lives in the item; a second name is created OUTSIDE the item and the file is appended through it.
    func testAppendThroughExternalHardLink() async throws {
        let inside = try fx.file("home/item/sub/f.log", bytes: 4096, modified: old)
        let (first, _) = try await scan("home/item")
        let outside = fx.abs("home/elsewhere/link.log")
        try FileManager.default.createDirectory(atPath: fx.abs("home/elsewhere"), withIntermediateDirectories: true)
        XCTAssertEqual(link(inside, outside), 0)
        try append(outside, 1 << 20)
        let (r, hit) = try await scan("home/item")
        XCTAssertFalse(hit, "stale entry served after a write through an external hard link")
        XCTAssertGreaterThan(r.logicalBytes, first.logicalBytes)
        XCTAssertGreaterThan(r.newestModification ?? .distantPast, Date().addingTimeInterval(-3600))
    }

    /// Hard link pre-existing at cache time (pnpm-store style), append through the external name.
    func testAppendThroughPreexistingExternalHardLink() async throws {
        let inside = try fx.file("home/item/f.log", bytes: 4096, modified: old)
        try FileManager.default.createDirectory(atPath: fx.abs("home/store"), withIntermediateDirectories: true)
        XCTAssertEqual(link(inside, fx.abs("home/store/f.log")), 0)
        _ = try await scan("home/item")
        try append(fx.abs("home/store/f.log"), 1 << 20)
        let (r, hit) = try await scan("home/item")
        XCTAssertFalse(hit)
        XCTAssertGreaterThan(r.newestModification ?? .distantPast, Date().addingTimeInterval(-3600))
    }

    /// Move a big old file into the item from another directory (mtime preserved by rename).
    func testRenameIntoFromOtherDir() async throws {
        try fx.file("home/item/a", bytes: 4096, modified: old)
        let big = try fx.file("home/other/big", bytes: 1 << 20, modified: old)
        let (first, _) = try await scan("home/item")
        XCTAssertEqual(rename(big, fx.abs("home/item/big")), 0)
        let (r, hit) = try await scan("home/item")
        XCTAssertFalse(hit); XCTAssertGreaterThan(r.logicalBytes, first.logicalBytes)
    }

    /// Move the whole parent of the item away and put a different tree at the same path.
    func testParentSwappedOut() async throws {
        try fx.file("home/p/item/a", bytes: 4096, modified: old)
        try fx.file("home/q/item/a", bytes: 1 << 20, modified: old)
        _ = try await scan("home/p/item")
        XCTAssertEqual(rename(fx.abs("home/p"), fx.abs("home/p-old")), 0)
        XCTAssertEqual(rename(fx.abs("home/q"), fx.abs("home/p")), 0)
        let (r, hit) = try await scan("home/p/item")
        XCTAssertFalse(hit); XCTAssertGreaterThan(r.logicalBytes, 1 << 19)
    }

    /// Append then forge the mtime back to the old value (size must still be fresh).
    func testAppendThenMtimeForgedBackwards() async throws {
        let f = try fx.file("home/item/d/f", bytes: 4096, modified: old)
        let (first, _) = try await scan("home/item")
        try append(f, 1 << 20)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f)
        let (r, hit) = try await scan("home/item")
        XCTAssertFalse(hit); XCTAssertGreaterThan(r.logicalBytes, first.logicalBytes)
    }

    /// Truncate in place.
    func testTruncateInPlace() async throws {
        let f = try fx.file("home/item/d/f", bytes: 1 << 20, modified: old)
        _ = try await scan("home/item")
        XCTAssertEqual(truncate(f, 10), 0)
        let (r, hit) = try await scan("home/item")
        XCTAssertFalse(hit); XCTAssertLessThan(r.logicalBytes, 1000)
    }

    /// Root is a single file appended in place.
    func testFileRootAppend() async throws {
        let f = try fx.file("home/single.log", bytes: 4096, modified: old)
        _ = try await scan("home/single.log")
        try append(f, 1 << 20)
        let (r, hit) = try await scan("home/single.log")
        XCTAssertFalse(hit); XCTAssertGreaterThan(r.logicalBytes, 1 << 19)
    }

    /// Tampered header: lastEventID pushed into the future. Journal "since future" returns nothing.
    func testFutureLastEventIDIsNotTrusted() async throws {
        let f = try fx.file("home/item/f", bytes: 4096, modified: old)
        _ = try await scan("home/item")
        try append(f, 1 << 20)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as! [String: Any]
        var header = json["header"] as! [String: Any]
        header["lastEventID"] = FSEventsGetCurrentEventId() + 10_000_000
        json["header"] = header
        try JSONSerialization.data(withJSONObject: json).write(to: cacheFile)
        let (_, hit) = try await scan("home/item")
        XCTAssertFalse(hit, "a lastEventID ahead of the current id must invalidate everything")
    }

    /// Very old lastEventID (history beyond retention / replay too large) must not be trusted.
    func testAncientLastEventIDInvalidates() async throws {
        try fx.file("home/item/f", bytes: 4096, modified: old)
        _ = try await scan("home/item")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as! [String: Any]
        var header = json["header"] as! [String: Any]
        header["lastEventID"] = 1
        json["header"] = header
        try JSONSerialization.data(withJSONObject: json).write(to: cacheFile)
        let (_, hit) = try await scan("home/item")
        XCTAssertFalse(hit)
    }

    /// Corrupt file → ignored and replaced; written 0600.
    func testCorruptFileIgnoredAndReplaced0600() async throws {
        try fx.file("home/item/f", bytes: 4096)
        try Data("{garbage".utf8).write(to: cacheFile)
        let (_, hit) = try await scan("home/item")
        XCTAssertFalse(hit)
        var st = stat(); XCTAssertEqual(stat(cacheFile.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)))
    }

    /// A world-writable cache file (someone else could have written it) is still loaded and trusted.
    func testWorldWritableCacheFileIsLoaded() async throws {
        try fx.file("home/item/f", bytes: 4096, modified: old)
        _ = try await scan("home/item")
        chmod(cacheFile.path, 0o666)
        let (_, hit) = try await scan("home/item")
        XCTAssertFalse(hit, "a cache file others can write must be ignored")
    }

    /// In-process race: a store from an older scan that lands after a newer beginScan consumed the journal.
    func testStoreFromSupersededScanSurvives() async throws {
        let f = try fx.file("home/item/f", bytes: 4096, modified: old)
        let j = FakeJournal()
        let c = SizeCache(fileURL: nil, journal: j)
        let ctx = try makeContext(fx, cache: c)
        await c.beginScan(options: ctx.sizerOptions)                // scan 1 (id 100)
        let stamp = await c.stamp(url("home/item"))
        let stale = try await FileSizer(options: ctx.sizerOptions).size(of: url("home/item"))  // scan 1's walk…
        try append(f, 1 << 20)                                      // …file written after the walk read it (event E)
        j.id = 200; j.result = .changed([f])                       // scan 2 begins and consumes E
        await c.beginScan(options: ctx.sizerOptions)
        await c.store(stale, for: url("home/item"), stamp: stamp)  // scan 1's late store
        j.id = 300; j.result = .changed([])                        // scan 3: nothing new since 200
        await c.beginScan(options: ctx.sizerOptions)
        let hit = await c.valid(url("home/item"))
        XCTAssertNil(hit, "stale report from a superseded scan is served (logical \(hit?.logicalBytes ?? -1))")
    }

    /// Rescan IMMEDIATELY after an in-place append (no settle): the event may be assigned an id before the next
    /// scan captures its id, yet not be returned by the history query -> stale hit, and the header then moves past it.
    func testImmediateRescanAfterAppend() async throws {
        var stale = 0, persisted = 0
        let n = 15
        for i in 0..<n {
            let rel = "home/loop\(i)"
            let f = try fx.file(rel + "/d/f.log", bytes: 4096, modified: old)
            _ = try await scan(rel)                          // settled warm
            _ = try await scan(rel)                          // settled warm hit
            try append(f, 1 << 20)
            let (r2, hit2) = try await scan(rel, settle: false)
            if hit2 && r2.logicalBytes < (1 << 20) { stale += 1
                let (r3, hit3) = try await scan(rel)         // settled: does the stale entry persist?
                if hit3 && r3.logicalBytes < (1 << 20) { persisted += 1 }
            }
        }
                XCTAssertEqual(stale, 0, "stale size served right after an append")
        XCTAssertEqual(persisted, 0, "stale entry persisted into later scans")
    }
}
