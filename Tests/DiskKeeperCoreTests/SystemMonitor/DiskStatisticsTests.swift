import XCTest
@testable import DiskKeeperCore

final class DiskStatisticsTests: XCTestCase {
    /// `IOBlockStorageDriver` "Statistics" as recorded from a MacBook's internal SSD (ioreg).
    private let recorded: [String: Any] = [
        "Operations (Write)": 101_688_325, "Latency Time (Write)": 0, "Bytes (Read)": 1_673_536_237_568, "Errors (Write)": 0,
        "Total Time (Read)": 14_190_488_525_407, "Latency Time (Read)": 0, "Retries (Read)": 0, "Errors (Read)": 0,
        "Total Time (Write)": 5_510_495_236_267, "Bytes (Write)": 2_114_303_303_680, "Operations (Read)": 64_855_339, "Retries (Write)": 0,
    ]

    func testParsesRecordedDictionary() throws {
        let s = try XCTUnwrap(DiskStatistics(dictionary: recorded))
        XCTAssertEqual(s.bytesRead, 1_673_536_237_568)
        XCTAssertEqual(s.bytesWritten, 2_114_303_303_680)
        XCTAssertEqual(s.totalTimeReadNs, 14_190_488_525_407)
        XCTAssertEqual(s.totalTimeWriteNs, 5_510_495_236_267)
    }

    func testMissingKeysGiveNil() {
        for key in ["Bytes (Read)", "Bytes (Write)", "Total Time (Read)", "Total Time (Write)"] {
            var d = recorded
            d[key] = nil
            XCTAssertNil(DiskStatistics(dictionary: d), key)
        }
        XCTAssertNil(DiskStatistics(dictionary: [:]))
    }

    func testRatesAndBusyClamp() throws {
        let t0 = ContinuousClock.now
        var tracker = DiskActivityTracker()
        let a = DiskStatistics(bytesRead: 0, bytesWritten: 0, totalTimeReadNs: 0, totalTimeWriteNs: 0)
        XCTAssertNil(tracker.update(a, at: t0))
        let b = DiskStatistics(bytesRead: 5_000, bytesWritten: 50_000, totalTimeReadNs: 1_000_000_000, totalTimeWriteNs: 500_000_000)
        let r = try XCTUnwrap(tracker.update(b, at: t0 + .seconds(5)))
        XCTAssertEqual(r.writeBytesPerSec, 10_000, accuracy: 0.01)
        XCTAssertEqual(r.readBytesPerSec, 1_000, accuracy: 0.01)
        XCTAssertEqual(r.busyFraction, 0.3, accuracy: 0.001)
        // Queue time larger than the wall time (parallel requests) clamps to 1.
        let c = DiskStatistics(bytesRead: 5_000, bytesWritten: 50_000, totalTimeReadNs: 61_000_000_000, totalTimeWriteNs: 500_000_000)
        XCTAssertEqual(try XCTUnwrap(tracker.update(c, at: t0 + .seconds(10))).busyFraction, 1)
    }

    func testCounterResetGivesNoRate() {
        let t0 = ContinuousClock.now
        var tracker = DiskActivityTracker()
        _ = tracker.update(DiskStatistics(bytesRead: 100, bytesWritten: 100, totalTimeReadNs: 1, totalTimeWriteNs: 1), at: t0)
        XCTAssertNil(tracker.update(DiskStatistics(bytesRead: 5, bytesWritten: 5, totalTimeReadNs: 1, totalTimeWriteNs: 1), at: t0 + .seconds(5)))
    }

    func testLiveReaderDoesNotCrash() {
        _ = LiveDiskStatisticsReader().read()   // may be nil on a VM; only proves the IOKit calls are sound
    }
}
