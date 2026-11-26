import AppKit
import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

/// F1 of the T50 verification: after the popover has been opened once, the hidden MenuBarExtra window must do no
/// work at all (no sampling, no observation of the models, no layout).
@MainActor
final class ClosedPopoverTests: XCTestCase {
    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    func testClosedPopoverViewIgnoresEveryModelUpdate() async {
        let r = MonitorRig()
        r.settings.setMetric(.cpu, inMenuBar: true)
        let care = CareRig()
        let env = AppEnvironment(pathEnvironment: PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp"),
                                 makeScanEngine: { FakeScanEngine(.scripted([])) })
        let host = NSHostingView(rootView: MenuBarPopover(model: r.menuBar, monitor: r.monitor, suite: SuiteModel(env: env)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin()
        _ = care

        // Open: the content is built.
        r.monitor.setPopoverOpen(true)
        spin(); host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(PopoverProbe.contentEvaluations, 0)

        // Close, then let the models churn the way ticks do.
        r.monitor.setPopoverOpen(false)
        spin(); host.layoutSubtreeIfNeeded()
        let shell = PopoverProbe.shellEvaluations, content = PopoverProbe.contentEvaluations
        for i in 0..<10 {
            r.counter.cpu = 0.1 + Double(i) * 0.05
            r.counter.mem = 0.2 + Double(i) * 0.05
            await r.scheduler.tick()
            r.time.now += .seconds(5)
            r.settings.setHistoryMinutes(i.isMultiple(of: 2) ? 1 : 5)
        }
        spin(); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(PopoverProbe.contentEvaluations, content, "closed popover content must not be re-evaluated")
        XCTAssertEqual(PopoverProbe.shellEvaluations, shell, "closed popover shell must not observe anything but its own visibility")
    }

    func testSamplerAndPopoverModelsDoZeroWorkAfterClose() async {
        let r = MonitorRig()                        // default bar: nothing but the glyph
        r.monitor.setPopoverOpen(true)
        await r.run(minutes: 1)
        XCTAssertGreaterThan(r.counter.count("cpu"), 0, "open popover samples")
        r.monitor.setPopoverOpen(false)
        r.counter.reset("cpu"); r.counter.reset("memory"); r.counter.reset("network"); r.counter.reset("processes"); r.counter.reset("cpuPerCore")
        r.renders.reset("render")
        let before = (r.monitor.cpu, r.monitor.memory, r.monitor.network, r.monitor.histories[.cpu]?.count)
        await r.run(minutes: 10)
        for k in ["cpu", "cpuPerCore", "memory", "network", "processes"] { XCTAssertEqual(r.counter.count(k), 0, "\(k) after close") }
        XCTAssertEqual(r.renders.count("render"), 0)
        XCTAssertEqual(before.0, r.monitor.cpu)
        XCTAssertEqual(before.3, r.monitor.histories[.cpu]?.count, "history stops growing")
    }

    func testClosedTopProcessesNeverReadsTheProcessList() async {
        let r = MonitorRig()
        r.settings.setShowsTopProcesses(true)
        r.monitor.setPopoverOpen(true)
        r.monitor.topProcessesExpanded = true
        await r.scheduler.tick()
        XCTAssertFalse(r.monitor.processes.isEmpty)
        r.monitor.setPopoverOpen(false)
        XCTAssertFalse(r.monitor.topProcessesExpanded, "closing collapses it, so processes stop being sampled")
        XCTAssertFalse(r.monitor.demand.topProcessesVisible)
    }

    func testUnchangedReadingsDoNotInvalidateObservers() async {
        let r = MonitorRig()
        r.monitor.setPopoverOpen(true)
        await r.scheduler.tick()
        var fired = 0
        withObservationTracking { _ = (r.monitor.cpu, r.monitor.memory, r.monitor.network, r.monitor.processes) } onChange: { fired += 1 }
        r.time.now += .seconds(2)
        await r.scheduler.tick()   // same fake values
        XCTAssertEqual(fired, 0)
    }
}

