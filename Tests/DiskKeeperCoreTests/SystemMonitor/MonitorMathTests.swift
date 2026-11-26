import XCTest
@testable import DiskKeeperCore

final class MonitorMathTests: XCTestCase {
    func testCPUUsageAndWrap() {
        let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = CPUTicks(user: 160, system: 80, idle: 860, nice: 50)   // +60 +30 +60 +0
        let u = CPULoadMath.usage(from: a, to: b)!
        XCTAssertEqual(u.total, 0.6, accuracy: 1e-9)
        XCTAssertEqual(u.user, 0.4, accuracy: 1e-9)
        XCTAssertEqual(u.system, 0.2, accuracy: 1e-9)
        // UInt32 wrap
        let w1 = CPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 9, nice: 0)
        let w2 = CPUTicks(user: 10, system: 0, idle: 10, nice: 0)   // +20, +20
        XCTAssertEqual(CPULoadMath.usage(from: w1, to: w2)!.total, 0.5, accuracy: 1e-9)
        XCTAssertNil(CPULoadMath.usage(from: a, to: a), "zero delta")
    }

    func testMemoryMath() {
        let page: UInt64 = 16384
        let v = VMCounts(internalPages: 300, purgeablePages: 50, wiredPages: 100, compressorPages: 60)
        let r = MemoryMath.reading(v, pageSize: page, totalBytes: 1000 * page, swapUsed: 7, pressure: .warning)
        XCTAssertEqual(r.appBytes, 250 * page)
        XCTAssertEqual(r.wiredBytes, 100 * page)
        XCTAssertEqual(r.compressedBytes, 60 * page)
        XCTAssertEqual(r.usedFraction, 0.41, accuracy: 1e-9)
        XCTAssertEqual(r.pressure, .warning)
        let over = MemoryMath.reading(VMCounts(internalPages: 5000, purgeablePages: 0, wiredPages: 0, compressorPages: 0),
                                      pageSize: page, totalBytes: 1000 * page, swapUsed: nil, pressure: nil)
        XCTAssertEqual(over.usedFraction, 1)
        XCTAssertEqual(MemoryMath.pressure(sysctlLevel: 4), .critical)
        XCTAssertNil(MemoryMath.pressure(sysctlLevel: 3), "unknown shows no pill")
    }

    func testNetworkRateWrapAndReset() {
        let a = [InterfaceCounters(name: "en0", inBytes: UInt32.max - 99, outBytes: 0)]
        let b = [InterfaceCounters(name: "en0", inBytes: 900, outBytes: 500)]   // +1000 across the wrap
        let r = NetworkMath.rate(previous: a, current: b, seconds: 2)!
        XCTAssertEqual(r.down, 500)
        XCTAssertEqual(r.up, 250)
        XCTAssertEqual(r.busiest, "en0")
        // interface set changed -> discard
        XCTAssertNil(NetworkMath.rate(previous: a, current: b + [InterfaceCounters(name: "en1", inBytes: 0, outBytes: 0)], seconds: 2))
        // counter reset (huge apparent delta) -> discard
        let reset = [InterfaceCounters(name: "en0", inBytes: 3_000_000_000, outBytes: 0)]
        XCTAssertNil(NetworkMath.rate(previous: [InterfaceCounters(name: "en0", inBytes: 10, outBytes: 0)], current: reset, seconds: 0.1))
        XCTAssertNil(NetworkMath.rate(previous: a, current: b, seconds: 0))
    }

    func testNetworkFilter() {
        for n in ["lo0", "utun3", "ipsec0", "awdl0", "llw0", "bridge100", "ap1", "gif0", "stf0", "anpi0", "vmenet0"] {
            XCTAssertFalse(NetworkMath.isCounted(n), n)
        }
        for n in ["en0", "en5", "pdp_ip0"] { XCTAssertTrue(NetworkMath.isCounted(n), n) }
    }

    func testTopNOrderingTiesByName() {
        let items = [ProcessUsage(pid: 3, name: "b", cpuPercent: 10, memoryBytes: 5),
                     ProcessUsage(pid: 1, name: "a", cpuPercent: 10, memoryBytes: 5),
                     ProcessUsage(pid: 2, name: "c", cpuPercent: 50, memoryBytes: 1)]
        XCTAssertEqual(ProcessTopN.top(items, by: .cpu).map(\.name), ["c", "a", "b"])
        XCTAssertEqual(ProcessTopN.top(items, by: .memory, limit: 2).map(\.name), ["a", "b"])
    }

    func testHistoryCapacityAgeAndOrder() {
        var h = MetricHistory(capacity: 3, maxAge: 100)
        for i in 0..<5 { h.append(time: Double(i), value: Double(i)) }
        XCTAssertEqual(h.count, 3)
        XCTAssertEqual(h.samples.map(\.value), [2, 3, 4])
        h.append(time: 200, value: 9)   // everything older than 100 s trimmed
        XCTAssertEqual(h.samples.map(\.value), [9])
        var big = MetricHistory()
        for i in 0..<1000 { big.append(time: Double(i) * 0.1, value: 1) }
        XCTAssertLessThanOrEqual(big.count, MetricHistory.defaultCapacity)
        XCTAssertEqual(big.window(1, now: 99.9).count, 11)
    }
}
