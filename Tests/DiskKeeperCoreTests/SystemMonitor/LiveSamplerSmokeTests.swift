import XCTest
@testable import DiskKeeperCore

/// Real, read-only samplers; safe on CI.
final class LiveSamplerSmokeTests: XCTestCase {
    func testCPUAfterTwoSamples() {
        var s = LiveCPUSampler()
        XCTAssertEqual(s.sample(perCore: true), .pending)
        var burn = 0.0
        for i in 0..<2_000_000 { burn += Double(i).squareRoot() }
        XCTAssertGreaterThan(burn, 0)
        guard case .value(let r) = s.sample(perCore: true) else { return XCTFail("no reading") }
        XCTAssertTrue((0...1).contains(r.total))
        XCTAssertEqual(r.perCore.count, ProcessInfo.processInfo.processorCount)
    }

    func testMemory() {
        var s = LiveMemorySampler()
        guard case .value(let r) = s.sample() else { return XCTFail("no reading") }
        XCTAssertGreaterThan(r.usedBytes, 0)
        XCTAssertLessThan(r.usedBytes, r.totalBytes)
    }

    func testNetworkRatesNonNegative() {
        var s = LiveNetworkSampler()
        _ = s.sample()
        Thread.sleep(forTimeInterval: 0.05)
        if case .value(let r) = s.sample() {
            XCTAssertGreaterThanOrEqual(r.downBytesPerSecond, 0)
            XCTAssertGreaterThanOrEqual(r.upBytesPerSecond, 0)
        }
    }

    func testProcessSamplerSeesItself() {
        var s = LiveProcessUsageSampler()
        _ = s.sample()
        let me = s.sample().first { $0.pid == getpid() }
        XCTAssertNotNil(me)
        XCTAssertGreaterThan(me?.memoryBytes ?? 0, 0)
    }
}
