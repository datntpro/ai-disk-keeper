import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

/// F4 (nothing sampled that nothing draws) and F5 (no first reading averaged over an idle gap).
@MainActor
final class DrawnMetricsAndStaleTests: XCTestCase {
    func testGlyphStyleSamplesNothingForTheBar() async {
        let r = MonitorRig()
        r.settings.setMetric(.cpu, inMenuBar: true)
        r.settings.setMetric(.network, inMenuBar: true)
        r.settings.setMenuBarStyle(.glyph)
        XCTAssertTrue(r.monitor.drawnBarMetrics.isEmpty)
        XCTAssertNil(SamplingPolicy.plan(r.monitor.demand).metricsInterval)
        await r.run(minutes: 3)
        for k in ["cpu", "memory", "network"] { XCTAssertEqual(r.counter.count(k), 0, k) }
        XCTAssertFalse(r.monitor.labelAccessibility.contains("%"), "nothing drawn, nothing spoken")
    }

    func testLiveStrataSamplesOnlyTheThreeMetersItDraws() async {
        let r = MonitorRig()
        for m in MetricID.allCases { r.settings.setMetric(m, inMenuBar: true) }
        r.settings.setMenuBarStyle(.liveStrata)
        let order = r.settings.settings.menuBarMetricsInOrder
        XCTAssertEqual(r.monitor.drawnBarMetrics, order.prefix(3).filter { $0 != .disk })
        let sampled = SamplingPolicy.plan(r.monitor.demand).metrics
        let fourth = order[3]
        if fourth != .disk { XCTAssertFalse(sampled.contains(fourth), "\(fourth) is not drawn") }
        r.settings.setMenuBarStyle(.readout)
        XCTAssertEqual(Set(r.monitor.drawnBarMetrics), Set(order.filter { $0 != .disk }))
    }

    func testStaleMetricRule() {
        let last: [MetricID: (at: Duration, interval: Duration)] = [.cpu: (.seconds(0), .seconds(5)), .network: (.seconds(0), .seconds(30))]
        XCTAssertEqual(MonitorScheduler.staleMetrics([.cpu, .network, .memory], last: last, now: .seconds(5)), [])
        XCTAssertEqual(MonitorScheduler.staleMetrics([.cpu, .network], last: last, now: .seconds(11)), [.cpu])
        XCTAssertEqual(MonitorScheduler.staleMetrics([.cpu, .network], last: last, now: .seconds(70)), [.cpu, .network])
    }

    func testFirstReadingAfterAnIdleGapIsDiscarded() async {
        let r = MonitorRig()
        r.settings.setMetric(.cpu, inMenuBar: true)
        await r.run(minutes: 1)                                  // bar sampling every 5 s
        XCTAssertNotNil(r.monitor.cpu.value)
        r.monitor.setPopoverOpen(false)
        r.settings.setMetric(.cpu, inMenuBar: false)             // nothing is sampled any more
        await r.run(minutes: 10)
        r.counter.cpu = 0.9
        r.settings.setMetric(.cpu, inMenuBar: true)             // sampling resumes after ten idle minutes
        await r.scheduler.tick()
        XCTAssertEqual(r.monitor.cpu, .pending, "the delta over the gap is not shown")
        r.time.now += .seconds(5)
        await r.scheduler.tick()
        XCTAssertEqual(r.monitor.cpu.value?.total, 0.9)
    }

    func testSteadySamplingNeverDiscards() async {
        let r = MonitorRig()
        r.settings.setMetric(.cpu, inMenuBar: true)
        await r.run(minutes: 2)
        XCTAssertNotNil(r.monitor.cpu.value)
        r.time.now += .seconds(5)
        await r.scheduler.tick()
        XCTAssertNotNil(r.monitor.cpu.value)
    }
}
