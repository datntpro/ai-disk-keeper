import XCTest
@testable import DiskKeeperCore

final class IORateTrackerTests: XCTestCase {
    private let t0 = ContinuousClock.now
    private func snap(after s: Int, _ records: [ProcessRecord]) -> ProcessTableSnapshot {
        ProcessTableSnapshot(at: t0 + .seconds(s), wall: Date(), records: records)
    }
    private func rec(_ pid: pid_t, start: UInt64 = 1, read: UInt64 = 0, written: UInt64) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: 1, name: "p", startID: start, diskBytesRead: read, diskBytesWritten: written)
    }

    func testTwoTicksGiveBytesPerSecond() {
        var t = IORateTracker()
        XCTAssertTrue(t.rates(snap(after: 0, [rec(10, read: 100, written: 1_000)])).isEmpty, "no previous value, no rate")
        let r = t.rates(snap(after: 5, [rec(10, read: 600, written: 11_000)]))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].writeBytesPerSec, 2_000, accuracy: 0.001)
        XCTAssertEqual(r[0].readBytesPerSec, 100, accuracy: 0.001)
    }

    func testPidReuseGivesNoRate() {
        var t = IORateTracker()
        _ = t.rates(snap(after: 0, [rec(10, start: 1, written: 9_000_000)]))
        XCTAssertTrue(t.rates(snap(after: 5, [rec(10, start: 2, written: 10)])).isEmpty)
        XCTAssertEqual(t.rates(snap(after: 10, [rec(10, start: 2, written: 5_010)])).first?.writeBytesPerSec ?? 0, 1_000, accuracy: 0.001)
    }

    func testCounterDecreaseGivesNoRateNeverNegative() {
        var t = IORateTracker()
        _ = t.rates(snap(after: 0, [rec(10, written: 5_000)]))
        XCTAssertTrue(t.rates(snap(after: 5, [rec(10, written: 100)])).isEmpty)
    }

    func testExitedProcessesAreReported() {
        var t = IORateTracker()
        _ = t.update(snap(after: 0, [rec(10, written: 700), rec(11, written: 5)]))
        let tick = t.update(snap(after: 5, [rec(11, written: 10)]))
        XCTAssertEqual(tick.exited, [ProcessKey(pid: 10, startID: 1)])
        XCTAssertEqual(tick.exitedBytesWritten, 700)
        XCTAssertEqual(tick.rates.count, 1)
    }
}
