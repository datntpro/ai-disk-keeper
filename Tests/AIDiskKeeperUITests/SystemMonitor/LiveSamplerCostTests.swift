import Darwin
import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

/// Real, read-only samplers: the per-tick cost must stay tiny. `ADK_SKIP_PERF=1` skips on slow runners.
final class LiveSamplerCostTests: XCTestCase {
    private func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    func testMedianTickCostUnderTwoMilliseconds() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ADK_SKIP_PERF"] == "1", "ADK_SKIP_PERF=1")
        let sampler = SystemSampler()
        var history = MetricHistory()
        var costs: [Double] = []
        _ = await sampler.sample(metrics: [.cpu, .memory, .network], perCore: false, topProcesses: false)   // warm up
        for i in 0..<50 {
            let before = cpuSeconds()
            let s = await sampler.sample(metrics: [.cpu, .memory, .network], perCore: false, topProcesses: false)
            costs.append(cpuSeconds() - before)
            if let v = s.cpu?.value?.total { history.append(time: Double(i), value: v) }
            XCTAssertLessThanOrEqual(history.count, MetricHistory.defaultCapacity)
        }
        let median = costs.sorted()[costs.count / 2]
        XCTAssertLessThan(median, 0.002, "median per tick \(median * 1000) ms")
    }
}
