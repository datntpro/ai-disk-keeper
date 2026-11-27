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

    private func rec(_ pid: pid_t, bornAt born: Date, written: UInt64) -> ProcessRecord {
        let sec = UInt64(born.timeIntervalSince1970)
        let usec = UInt64((born.timeIntervalSince1970 - Double(sec)) * 1_000_000)
        return ProcessRecord(pid: pid, ppid: 1, name: "dd", startID: (sec << 20) | usec, diskBytesWritten: written)
    }

    func testProcessBornBetweenTicksCountsItsWholeCounter() {
        let wall0 = Date(timeIntervalSince1970: 1_700_000_000)
        var t = IORateTracker()
        _ = t.rates(ProcessTableSnapshot(at: t0, wall: wall0, records: []))
        let born = wall0.addingTimeInterval(2)
        let r = t.rates(ProcessTableSnapshot(at: t0 + .seconds(5), wall: wall0.addingTimeInterval(5),
                                             records: [rec(50, bornAt: born, written: 50_000_000)]))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].writeBytesPerSec, 10_000_000, accuracy: 1, "50 MB written during a 5 s tick")
    }

    func testOldProcessFirstSeenGetsNoWholeCounterRate() {
        let wall0 = Date(timeIntervalSince1970: 1_700_000_000)
        var t = IORateTracker()
        _ = t.rates(ProcessTableSnapshot(at: t0, wall: wall0, records: []))
        // Started an hour before the previous tick (e.g. it was just outside our uid view or the table was empty).
        let r = t.rates(ProcessTableSnapshot(at: t0 + .seconds(5), wall: wall0.addingTimeInterval(5),
                                             records: [rec(51, bornAt: wall0.addingTimeInterval(-3600), written: 9_000_000_000)]))
        XCTAssertTrue(r.isEmpty, "its lifetime counter is not this interval's I/O")
    }

    func testLongGapStartsANewBaseline() {
        var t = IORateTracker()
        _ = t.rates(snap(after: 0, [rec(10, written: 1_000)]))
        XCTAssertTrue(t.rates(snap(after: 600, [rec(10, written: 9_000_000)])).isEmpty, "10 minutes of closed popover is not one rate")
        XCTAssertEqual(t.rates(snap(after: 605, [rec(10, written: 9_005_000)])).first?.writeBytesPerSec ?? 0, 1_000, accuracy: 0.01)
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
