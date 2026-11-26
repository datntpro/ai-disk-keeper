import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class StorageModelTests: XCTestCase {
    private func make(_ counter: LoadCounter, now: @escaping () -> Date = { StorageFix.now }) -> StorageModel {
        StorageModel(load: { try await counter.next() }, clock: now, minInterval: 60)
    }

    func testDerivedValuesUseImportantUsageAsFree() async {
        let counter = LoadCounter([.success(StorageFix.overview())])
        let m = make(counter)
        m.refresh()
        await m.settle()
        XCTAssertEqual(m.freeBytes, 182 * StorageFix.gb)
        XCTAssertEqual(m.strictFreeBytes, 150 * StorageFix.gb)
        XCTAssertEqual(m.purgeableBytes, 32 * StorageFix.gb)
        XCTAssertEqual(m.usedBytes, 312 * StorageFix.gb)
        XCTAssertEqual(m.usedFraction ?? 0, 312.0 / 494.0, accuracy: 1e-9)
        XCTAssertEqual(m.segments.map(\.id), ["storage.data", "storage.system", "storage.other", "storage.purgeable"])
        XCTAssertEqual(m.segments.first?.bytes, 248 * StorageFix.gb)   // data used excludes purgeable
    }

    func testFreeFallsBackToStrictAndUnknownSegmentsAreOmitted() async {
        let counter = LoadCounter([.success(StorageFix.overview(important: nil, used: nil))])
        let m = make(counter)
        m.refresh()
        await m.settle()
        XCTAssertEqual(m.freeBytes, 150 * StorageFix.gb)
        XCTAssertNil(m.purgeableBytes)
        XCTAssertFalse(m.segments.contains { $0.id == "storage.data" || $0.id == "storage.purgeable" })
        XCTAssertFalse(m.segments.contains { $0.bytes == 0 })
    }

    func testValuesAreNilBeforeTheFirstMeasurement() {
        let m = make(LoadCounter([.success(StorageFix.overview())]))
        XCTAssertNil(m.freeBytes)
        XCTAssertNil(m.usedFraction)
        XCTAssertTrue(m.segments.isEmpty)
    }

    func testRefreshCoalescesAndThrottles() async {
        let counter = LoadCounter([.success(StorageFix.overview())])
        var t = StorageFix.now
        let m = make(counter, now: { t })
        m.refresh(); m.refresh()
        await m.settle()
        t = t.addingTimeInterval(1)
        m.refresh()
        await m.settle()
        let afterThrottle = await counter.count
        XCTAssertEqual(afterThrottle, 1)
        m.refresh(force: true)
        await m.settle()
        t = t.addingTimeInterval(120)
        m.refresh()
        await m.settle()
        let total = await counter.count
        XCTAssertEqual(total, 3)
    }

    func testLastGoodValueSurvivesAFailure() async {
        let counter = LoadCounter([.success(StorageFix.overview()), .failure(StorageFixError())])
        let m = make(counter)
        m.refresh()
        await m.settle()
        m.refresh(force: true)
        await m.settle()
        XCTAssertEqual(m.phase, .failed("boom"))
        XCTAssertNotNil(m.overview)
        XCTAssertEqual(m.freeBytes, 182 * StorageFix.gb)
    }

    func testNoteCleanupFinishedForcesARefresh() async {
        let counter = LoadCounter([.success(StorageFix.overview())])
        let m = make(counter)
        m.refresh()
        await m.settle()
        m.noteCleanupFinished()
        await m.settle()
        let n = await counter.count
        XCTAssertEqual(n, 2)
    }

    /// "Free" is built from `availableForImportantUsage`, the way `LiveVolumeInfoProvider` fills `VolumeInfo`.
    func testFreeUsesAvailableForImportantUsageKey() async throws {
        let live = try await LiveVolumeInfoProvider().info(forPath: NSTemporaryDirectory())
        let counter = LoadCounter([.success(StorageOverview(dataVolume: live, systemVolume: nil, snapshots: .listed([]),
                                                            trash: TrashInfo(path: "/x", state: .measured, allocatedBytes: 0, itemCount: 0),
                                                            measuredAt: StorageFix.now))])
        let m = make(counter)
        m.refresh()
        await m.settle()
        XCTAssertEqual(m.freeBytes, live.availableForImportantUsage ?? live.availableBytes)
    }
}
