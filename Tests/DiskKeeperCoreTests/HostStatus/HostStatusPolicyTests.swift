import XCTest
@testable import DiskKeeperCore

final class HostStatusPolicyTests: XCTestCase {
    private let total: Int64 = 500_000_000_000

    private func eval(_ s: HostStatusSample, prev: HostStatusSample? = nil, threshold: Int = 15) -> (HostStatusLevel, [HostStatusReasonCode]) {
        let r = HostStatusPolicy.evaluate(s, previous: prev, thresholdPercent: threshold)
        return (r.level, r.reasons.map(\.code))
    }

    func testFreeSpaceRules() {
        XCTAssertEqual(eval(.init(freeBytes: 200_000_000_000, totalBytes: total)).0, .ok)
        let warn = eval(.init(freeBytes: 65_000_000_000, totalBytes: total))   // 13 %
        XCTAssertEqual(warn.0, .warn); XCTAssertEqual(warn.1, [.lowFreeSpace])
        XCTAssertEqual(eval(.init(freeBytes: 20_000_000_000, totalBytes: total)).0, .critical, "4 %")
        XCTAssertEqual(eval(.init(freeBytes: 9_000_000_000, totalBytes: 100_000_000_000)).0, .critical, "< 10 GB")
        XCTAssertEqual(eval(.init(freeBytes: 65_000_000_000, totalBytes: total), threshold: 10).0, .ok, "threshold is the setting")
        XCTAssertEqual(eval(.init(freeBytes: nil, totalBytes: nil)).0, .ok, "unknown is not an alarm")
    }

    func testTimeToFull() {
        let free: Int64 = 300_000_000_000
        XCTAssertEqual(eval(.init(freeBytes: free, totalBytes: total, timeToFullHours: 5.9)).0, .critical)
        XCTAssertEqual(eval(.init(freeBytes: free, totalBytes: total, timeToFullHours: 6)).0, .warn)
        XCTAssertEqual(eval(.init(freeBytes: free, totalBytes: total, timeToFullHours: 47.9)).1, [.fullSoon])
        XCTAssertEqual(eval(.init(freeBytes: free, totalBytes: total, timeToFullHours: 48)).0, .ok)
    }

    func testWritesNeedTwoSamples() {
        let hot = HostStatusSample(writeBytesPerSec: 250_000_000)
        let cold = HostStatusSample(writeBytesPerSec: 1_000)
        XCTAssertEqual(eval(hot).0, .ok, "first hot sample")
        XCTAssertEqual(eval(hot, prev: cold).0, .ok)
        XCTAssertEqual(eval(hot, prev: hot).1, [.highDiskWrites])
        XCTAssertEqual(eval(cold, prev: hot).0, .ok)
        XCTAssertEqual(eval(.init(writeBytesPerSec: 200_000_000), prev: hot).0, .ok, "not above 200 MB/s")
    }

    func testLoadNeedsTwoSamples() {
        let busy = HostStatusSample(loadAverage1: 8.5, cpuCount: 10)
        let calm = HostStatusSample(loadAverage1: 7.9, cpuCount: 10)
        XCTAssertEqual(eval(busy).0, .ok)
        XCTAssertEqual(eval(busy, prev: calm).0, .ok)
        XCTAssertEqual(eval(busy, prev: busy).1, [.highLoad])
        XCTAssertEqual(eval(calm, prev: calm).0, .ok, "80 % of 10 cores is 8.0")
    }

    func testMemoryPressureIsImmediate() {
        XCTAssertEqual(eval(.init(memoryPressure: .normal)).0, .ok)
        XCTAssertEqual(eval(.init(memoryPressure: .warning)).1, [.memoryPressure])
        XCTAssertEqual(eval(.init(memoryPressure: .critical)).0, .warn)
    }

    func testWorstLevelWinsAndReasonsAccumulate() {
        let s = HostStatusSample(freeBytes: 10_000_000_000, totalBytes: total, timeToFullHours: 30, memoryPressure: .warning)
        let r = eval(s)
        XCTAssertEqual(r.0, .critical)
        XCTAssertEqual(r.1, [.lowFreeSpace, .fullSoon, .memoryPressure])
    }
}
