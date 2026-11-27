import XCTest
@testable import DiskKeeperCore

final class FreeSpaceHistoryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_100)   // 100 s into a bucket

    func testBucketsKeepTheMinimum() {
        var h = FreeSpaceHistory()
        XCTAssertTrue(h.record(freeBytes: 500, at: base))
        XCTAssertFalse(h.record(freeBytes: 300, at: base.addingTimeInterval(60)))
        XCTAssertFalse(h.record(freeBytes: 400, at: base.addingTimeInterval(120)))
        XCTAssertEqual(h.points.count, 1)
        XCTAssertEqual(h.points[0].freeBytes, 300)
        XCTAssertEqual(h.points[0].t % 600, 0)
        XCTAssertTrue(h.record(freeBytes: 250, at: base.addingTimeInterval(600)))
        XCTAssertEqual(h.points.count, 2)
    }

    func testSevenDayCap() {
        var h = FreeSpaceHistory()
        var last = base
        for i in 0..<(1008 + 200) {
            last = base.addingTimeInterval(Double(i) * 600)
            h.record(freeBytes: Int64(i), at: last)
        }
        XCTAssertEqual(h.points.count, FreeSpaceHistory.maxPoints)
        XCTAssertEqual(h.points.last?.freeBytes, 1207)
        XCTAssertGreaterThanOrEqual(h.points.first!.t, Int(last.timeIntervalSince1970) - 1008 * 600)
    }

    func testClockGoingBackDropsNewerPoints() {
        var h = FreeSpaceHistory()
        h.record(freeBytes: 1, at: base.addingTimeInterval(3_000))
        h.record(freeBytes: 2, at: base)
        XCTAssertEqual(h.points.map(\.freeBytes), [2])
    }

    func testStoreRoundTripPermissionsAndCorruptFile() throws {
        let dir = try TemporaryDirectory()
        let store = FreeSpaceHistoryStore(fileURL: dir.url.appendingPathComponent("AIDiskKeeper/free-space-history.json"))
        XCTAssertTrue(store.load().points.isEmpty)
        var h = FreeSpaceHistory()
        h.record(freeBytes: 42, at: base)
        try store.save(h)
        XCTAssertEqual(store.load(), h)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        try Data("{ nope".utf8).write(to: store.fileURL)
        XCTAssertTrue(store.load().points.isEmpty, "a corrupt file reads as empty")
        try store.save(h)
        XCTAssertEqual(store.load(), h, "and is replaced")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["free-space-history.json"])
    }
}
