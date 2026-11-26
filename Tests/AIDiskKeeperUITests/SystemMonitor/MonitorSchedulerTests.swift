import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class MonitorSchedulerTests: XCTestCase {
    func testDefaultSamplesNoMetricsOnlyTheDiskProbe() async {
        let r = MonitorRig()
        await r.run(minutes: 10)
        for k in ["cpu", "memory", "network", "cpuPerCore", "processes"] { XCTAssertEqual(r.counter.count(k), 0, k) }
        XCTAssertEqual(r.probeCalls.count("probe"), 10)
    }

    func testBarMetricsSampleEvery5sWithoutPerCoreOrProcesses() async {
        let r = MonitorRig()
        r.settings.setMetric(.cpu, inMenuBar: true)
        r.settings.setMetric(.memory, inMenuBar: true)
        r.settings.setMetric(.network, inMenuBar: true)
        await r.run(minutes: 1)
        for k in ["cpu", "memory", "network"] { XCTAssertEqual(r.counter.count(k), 12, k) }
        XCTAssertEqual(r.counter.count("cpuPerCore"), 0)
        XCTAssertEqual(r.counter.count("processes"), 0)
        XCTAssertEqual(r.probeCalls.count("probe"), 1)
    }

    func testPopoverOpenSamples2sAndProcessesOnlyWhenExpanded() async {
        let r = MonitorRig()
        r.settings.setShowsTopProcesses(true)
        r.monitor.setPopoverOpen(true)
        await r.run(minutes: 1)
        for k in ["cpu", "memory", "network", "cpuPerCore"] { XCTAssertEqual(r.counter.count(k), 30, k) }
        XCTAssertEqual(r.counter.count("processes"), 0, "collapsed: no process sampling")
        r.monitor.topProcessesExpanded = true
        await r.run(minutes: 1)
        XCTAssertEqual(r.counter.count("processes"), 15)
        XCTAssertEqual(r.counter.count("cpu"), 60)
    }

    func testClosingThePopoverStopsMetricSampling() async {
        let r = MonitorRig()
        r.monitor.setPopoverOpen(true)
        await r.run(minutes: 1)
        r.monitor.setPopoverOpen(false)
        let before = r.counter.count("cpu")
        await r.run(minutes: 5)
        XCTAssertEqual(r.counter.count("cpu"), before)
    }

    func testDisabledMetricIsNeverSampled() async {
        let r = MonitorRig()
        r.settings.setMetric(.cpu, inMenuBar: true)
        r.settings.setMetric(.cpu, monitored: false)
        r.monitor.setPopoverOpen(true)
        await r.run(minutes: 1)
        XCTAssertEqual(r.counter.count("cpu"), 0)
        XCTAssertGreaterThan(r.counter.count("memory"), 0)
    }

    func testHiddenItemAndDisplaySleepStopMetricsButKeepTheDiskPoll() async {
        for configure in [{ (r: MonitorRig) in r.settings.setShowMenuBarItem(false) },
                          { (r: MonitorRig) in r.monitor.setDisplayAsleep(true) }] {
            let r = MonitorRig()
            r.settings.setMetric(.cpu, inMenuBar: true)
            r.monitor.setPopoverOpen(true)
            configure(r)
            await r.run(minutes: 5)
            XCTAssertEqual(r.counter.count("cpu"), 0)
            XCTAssertEqual(r.probeCalls.count("probe"), 5)
        }
    }

    func testSystemSleepStopsEverything() async {
        let r = MonitorRig()
        r.monitor.setSystemAsleep(true)
        r.settings.setMetric(.cpu, inMenuBar: true)
        await r.scheduler.tick()
        XCTAssertEqual(r.counter.count("cpu"), 0)
        XCTAssertEqual(r.probeCalls.count("probe"), 0)
        XCTAssertEqual(r.scheduler.nextDelay(), MonitorScheduler.idleSleep)
    }

    func testWakeSamplesOnceImmediately() async {
        let r = MonitorRig()
        r.settings.setMetric(.cpu, inMenuBar: true)
        await r.run(minutes: 1)
        await r.scheduler.tick()   // the sample that was due at 60 s
        let before = r.counter.count("cpu")
        r.time.now += .seconds(1)   // mid-interval: nothing is due
        await r.scheduler.tick()
        XCTAssertEqual(r.counter.count("cpu"), before)
        r.scheduler.wake { $0.monitor.setDisplayAsleep(false) }
        await r.scheduler.tick()
        XCTAssertEqual(r.counter.count("cpu"), before + 1)
    }

    func testOpeningThePopoverSamplesImmediately() async {
        let r = MonitorRig()
        await r.scheduler.tick()   // default: disk only
        r.time.now += .seconds(1)
        r.monitor.onDemandChange = { [scheduler = r.scheduler] in scheduler.demandChanged() }
        r.monitor.setPopoverOpen(true)
        await r.scheduler.tick()
        XCTAssertEqual(r.counter.count("cpu"), 1)
    }

    func testOneLoopOnly() async {
        let r = MonitorRig()
        r.scheduler.start(observeSystem: false)
        r.scheduler.start(observeSystem: false)
        XCTAssertEqual(r.scheduler.loopsStarted, 1)
        r.monitor.setPopoverOpen(true)   // demand change restarts the sleep, not the loop
        r.settings.setMetric(.cpu, inMenuBar: true)
        r.monitor.setPopoverOpen(false)
        await Task.yield()
        XCTAssertEqual(r.scheduler.loopsStarted, 1)
        r.scheduler.stop()
        XCTAssertFalse(r.scheduler.isRunning)
    }

    func testPlannerSlackAndDelay() {
        var p = MonitorPlanner()
        var d = Demand()
        d.barMetrics = [.cpu]
        let plan = SamplingPolicy.plan(d)
        XCTAssertEqual(p.delay(at: .zero, plan: plan), .zero)
        XCTAssertFalse(p.due(at: .zero, plan: plan).isEmpty)
        XCTAssertEqual(p.delay(at: .seconds(1), plan: plan), .seconds(4))
        XCTAssertTrue(p.due(at: .seconds(2), plan: plan).isEmpty)
    }
}
