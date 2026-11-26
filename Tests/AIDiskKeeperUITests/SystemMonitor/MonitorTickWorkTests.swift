import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class MonitorTickWorkTests: XCTestCase {
    func testOneTickCallsEachDueSamplerOnceAndNeverRefreshesStorage() async {
        let r = MonitorRig()
        r.monitor.setPopoverOpen(true)
        await r.scheduler.tick()
        for k in ["cpu", "memory", "network", "cpuPerCore"] { XCTAssertEqual(r.counter.count(k), 1, k) }
        XCTAssertEqual(r.counter.count("processes"), 0)
        XCTAssertEqual(r.probeCalls.count("probe"), 1)
        XCTAssertEqual(r.storageLoads.count("load"), 0, "a tick must not run the full overview (tmutil + Trash walk)")
    }

    func testLabelRendersOnlyWhenTheVisibleContentChanges() async {
        let r = MonitorRig()
        r.settings.setMetric(.cpu, inMenuBar: true)
        r.renders.reset("render")
        await r.scheduler.tick()          // pending -> 30%: content changes
        XCTAssertEqual(r.renders.count("render"), 1)
        r.time.now += .seconds(5)
        await r.scheduler.tick()          // same value
        XCTAssertEqual(r.renders.count("render"), 1, "unchanged values publish nothing")
        r.counter.cpu = 0.62
        r.time.now += .seconds(5)
        await r.scheduler.tick()
        XCTAssertEqual(r.renders.count("render"), 2)
    }

    func testDefaultBarTickNeverTouchesTheRenderer() async {
        let r = MonitorRig()
        r.renders.reset("render")
        await r.run(minutes: 3)
        XCTAssertEqual(r.renders.count("render"), 0)
    }

    func testNetworkFailureIsReportedNotHidden() async {
        let r = MonitorRig(failNetwork: true)
        r.monitor.setPopoverOpen(true)
        await r.scheduler.tick()
        XCTAssertEqual(r.monitor.network, .failed)
        XCTAssertNotNil(r.monitor.cpu.value, "other metrics keep working")
    }

    func testHistoryNeverExceedsCapacity() async {
        let r = MonitorRig()
        r.monitor.setPopoverOpen(true)
        await r.run(minutes: 20)
        for id in [SystemMonitorModel.SeriesID.cpu, .memory, .down, .up] {
            XCTAssertLessThanOrEqual(r.monitor.histories[id]?.count ?? 0, MetricHistory.defaultCapacity)
        }
    }
}
