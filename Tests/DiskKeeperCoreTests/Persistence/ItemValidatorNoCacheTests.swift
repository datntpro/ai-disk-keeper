import XCTest
@testable import DiskKeeperCore

/// The execute-time re-size must never see the scan cache (T25): a poisoned cache cannot hide a change.
final class ItemValidatorNoCacheTests: CleanupTestCase {
    func testExecuteTimeResizeIgnoresPoisonedCache() async throws {
        try fx.file("home/cache/a", bytes: 8192)
        let it = try item("home/cache/a")
        // Poison: a cache that claims the item is tiny and old.
        let journal = FakeJournal()
        let cache = SizeCache(fileURL: nil, journal: journal)
        await cache.beginScan(options: .init())
        let stamp = await cache.stamp(it.url)
        await cache.store(SizeReport(rootKind: .file, allocatedBytes: it.sizeAllocated,
                                     newestModification: it.lastModified), for: it.url, stamp: stamp)
        // The file really grows; the cache would still say "unchanged".
        try fx.file("home/cache/a", bytes: 1_000_000)
        let validator = ItemValidator(pathGuard: try makeGuard(), userID: getuid(), runningApps: FakeRunningApps(),
                                       tolerance: ChangeTolerance(mtimeSlack: 0, sizeSlackBytes: 0, sizeSlackFraction: 0))
        let blockers = await validator.changeCheck(it)
        XCTAssertEqual(blockers.map(\.code), ["changedSinceScan"])
    }
}
