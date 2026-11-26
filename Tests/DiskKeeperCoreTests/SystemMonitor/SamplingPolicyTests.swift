import XCTest
@testable import DiskKeeperCore

final class SamplingPolicyTests: XCTestCase {
    private func demand(_ f: (inout Demand) -> Void = { _ in }) -> Demand { var d = Demand(); f(&d); return d }

    func testDefaultSamplesNothingButDisk() {
        let p = SamplingPolicy.plan(demand())
        XCTAssertNil(p.metricsInterval)
        XCTAssertTrue(p.metrics.isEmpty)
        XCTAssertEqual(p.diskInterval, .seconds(60))
    }

    func testBarMetricsUseBarIntervalWithoutPerCore() {
        let p = SamplingPolicy.plan(demand { $0.barMetrics = [.cpu, .network, .disk]; $0.barInterval = .seconds(10) })
        XCTAssertEqual(p.metrics, [.cpu, .network])
        XCTAssertEqual(p.metricsInterval, .seconds(10))
        XCTAssertFalse(p.perCore)
        XCTAssertFalse(p.topProcesses)
    }

    func testDisabledMetricIsNeverSampled() {
        let p = SamplingPolicy.plan(demand { $0.barMetrics = [.cpu, .memory]; $0.enabledMetrics = [.disk, .memory] })
        XCTAssertEqual(p.metrics, [.memory])
        let open = SamplingPolicy.plan(demand { $0.popoverOpen = true; $0.enabledMetrics = [.disk, .cpu] })
        XCTAssertEqual(open.metrics, [.cpu])
    }

    func testPopoverOpen() {
        let p = SamplingPolicy.plan(demand { $0.popoverOpen = true })
        XCTAssertEqual(p.metrics, [.cpu, .memory, .network])
        XCTAssertEqual(p.metricsInterval, .seconds(2))
        XCTAssertTrue(p.perCore)
        XCTAssertFalse(p.topProcesses)
        XCTAssertTrue(SamplingPolicy.plan(demand { $0.popoverOpen = true; $0.topProcessesVisible = true }).topProcesses)
        XCTAssertFalse(SamplingPolicy.plan(demand { $0.topProcessesVisible = true }).topProcesses, "never with the popover closed")
    }

    func testHiddenAsleepStates() {
        for d in [demand { $0.itemInserted = false; $0.popoverOpen = true; $0.barMetrics = [.cpu] },
                  demand { $0.displayAsleep = true; $0.popoverOpen = true; $0.barMetrics = [.cpu] }] {
            let p = SamplingPolicy.plan(d)
            XCTAssertTrue(p.metrics.isEmpty)
            XCTAssertEqual(p.diskInterval, .seconds(60))
        }
        let s = SamplingPolicy.plan(demand { $0.systemAsleep = true; $0.popoverOpen = true })
        XCTAssertNil(s.diskInterval)
        XCTAssertNil(s.metricsInterval)
    }

    func testSnap() {
        XCTAssertEqual(SamplingPolicy.snapBarSeconds(1), 2)
        XCTAssertEqual(SamplingPolicy.snapBarSeconds(7), 5)
        XCTAssertEqual(SamplingPolicy.snapBarSeconds(8), 10)
        XCTAssertEqual(SamplingPolicy.snapBarSeconds(500), 30)
    }
}
