import XCTest
@testable import DiskKeeperCore

final class FreeSpaceTrendTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000
    private let start = 1_700_000_000 / 600 * 600

    /// One point per 10 minutes for `hours`, free = `from` minus `perHour` bytes per hour (plus `noise(i)`).
    private func series(hours: Int, from: Int64, perHour: Int64, noise: (Int) -> Int64 = { _ in 0 }, offsetBuckets: Int = 0) -> [FreeSpaceHistory.Point] {
        var out: [FreeSpaceHistory.Point] = []
        for i in 0...(hours * 6) {
            let t: Int = start + (offsetBuckets + i) * 600
            let drop: Int64 = perHour * Int64(i) / 6
            let free: Int64 = from - drop + noise(i)
            out.append(FreeSpaceHistory.Point(t: t, freeBytes: free))
        }
        return out
    }
    private func now(_ pts: [FreeSpaceHistory.Point]) -> Date { pts.last!.date }

    func testLinearDeclineGivesEtaWithinFivePercent() throws {
        let pts = series(hours: 24, from: 100 * gb, perHour: 2 * gb)   // 100 GB at t0, -2 GB/h → 52 GB left → 26 h
        let t = try XCTUnwrap(FreeSpaceTrend.estimate(pts, now: now(pts)))
        XCTAssertEqual(try XCTUnwrap(t.timeToFull), 26 * 3600, accuracy: 26 * 3600 * 0.05)
        XCTAssertEqual(t.bytesPerHour, -2e9, accuracy: 2e9 * 0.01)
        XCTAssertGreaterThan(t.r2, 0.99)
    }

    func testCleanupJumpResetsTheWindow() throws {
        let before = series(hours: 20, from: 50 * gb, perHour: 3 * gb)                     // falling fast
        let afterStart = before.last!.t + 600
        var after: [FreeSpaceHistory.Point] = []
        for i in 0...(8 * 6) {
            let free: Int64 = 120 * gb - Int64(i) * gb / 6   // -1 GB/h
            after.append(FreeSpaceHistory.Point(t: afterStart + i * 600, freeBytes: free))
        }
        let pts = before + after
        let t = try XCTUnwrap(FreeSpaceTrend.estimate(pts, now: now(pts)))
        XCTAssertEqual(t.bytesPerHour, -1e9, accuracy: 0.05e9, "only the window after the jump counts")
        let expected: Double = Double(after.last!.freeBytes) / 1e9 * 3600
        XCTAssertEqual(try XCTUnwrap(t.timeToFull), expected, accuracy: 3600 * 3)
    }

    func testNotEnoughHistoryAfterACleanupIsNil() {
        let before = series(hours: 20, from: 50 * gb, perHour: 3 * gb)
        let lastT: Int = before.last!.t
        var after: [FreeSpaceHistory.Point] = []
        for i in 0...(3 * 6) {
            let free: Int64 = 120 * gb - Int64(i) * gb / 6
            after.append(FreeSpaceHistory.Point(t: lastT + 600 + i * 600, freeBytes: free))
        }
        XCTAssertNil(FreeSpaceTrend.estimate(before + after, now: Date()), "3 h after the cleanup is not enough")
    }

    func testFlatIsStableWithNoEta() throws {
        let pts = series(hours: 24, from: 100 * gb, perHour: 0)
        let t = try XCTUnwrap(FreeSpaceTrend.estimate(pts, now: now(pts)))
        XCTAssertNil(t.timeToFull)
    }

    func testRisingIsStable() throws {
        let pts = series(hours: 24, from: 100 * gb, perHour: -gb / 10)
        XCTAssertNil(try XCTUnwrap(FreeSpaceTrend.estimate(pts, now: now(pts))).timeToFull)
    }

    func testNoisyDeclineIsNil() {
        let noise: (Int) -> Int64 = { (i: Int) -> Int64 in
            let sign: Int64 = i % 2 == 0 ? 1 : -1
            let magnitude: Int64 = Int64((i * 7919) % 13)
            return sign * magnitude * 500_000_000
        }
        let pts = series(hours: 24, from: 100 * gb, perHour: gb / 50, noise: noise)
        XCTAssertNil(FreeSpaceTrend.estimate(pts, now: now(pts)))
    }

    func testUnderSixHoursIsNil() {
        let pts = series(hours: 5, from: 100 * gb, perHour: 2 * gb)
        XCTAssertNil(FreeSpaceTrend.estimate(pts, now: now(pts)))
    }

    func testBeyondThirtyDaysHidesTheEta() throws {
        let pts = series(hours: 48, from: 400 * gb, perHour: gb / 10)   // 400 GB / 0.1 GB/h = 4000 h > 30 d
        let t = try XCTUnwrap(FreeSpaceTrend.estimate(pts, now: now(pts)))
        XCTAssertNil(t.timeToFull)
    }

    func testStatusLevels() {
        func level(_ freeGB: Double, total: Int64 = 500 * 1_000_000_000, _ threshold: Int = 15) -> FreeSpaceLevel {
            FreeSpaceStatus(freeBytes: Int64(freeGB * 1e9), totalBytes: total, thresholdPercent: threshold, trend: nil).level
        }
        XCTAssertEqual(level(200), .ok)
        XCTAssertEqual(level(75), .ok, "exactly 15 % is not low")
        XCTAssertEqual(level(74), .warning)
        XCTAssertEqual(level(26), .warning)
        XCTAssertEqual(level(24), .critical, "under 5 %")
        XCTAssertEqual(level(9, total: 2_000 * 1_000_000_000), .critical, "under 10 GB even when that is under 5 % of a huge disk")
        XCTAssertEqual(level(74, 10), .ok, "a saved 10 % threshold is respected")
        XCTAssertEqual(level(49, 10), .warning)
    }
}
