import DiskKeeperCore
import SwiftUI
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class SystemMonitorRenderTests: XCTestCase {
    private func render(_ view: some View, _ what: String) {
        for language in [AppLanguage.en, .vi] {
            L10n.apply(language)
            defer { L10n.apply(.en) }
            for scheme in [ColorScheme.light, .dark] {
                for contrast in [false, true] {
                    let r = ImageRenderer(content: view.frame(width: 320).environment(\.colorScheme, scheme)
                        .environment(\.adkIncreasedContrast, contrast))
                    XCTAssertNotNil(r.cgImage, "\(what) \(language) \(scheme)")
                }
            }
        }
    }

    func testPopoverSectionStates() async {
        // collecting
        let collecting = MonitorRig()
        render(SystemMonitorSection(monitor: collecting.monitor), "collecting")
        // values (after a few ticks), processes expanded
        let values = MonitorRig()
        values.settings.setShowsTopProcesses(true)
        values.monitor.setPopoverOpen(true)
        values.monitor.topProcessesExpanded = true
        for _ in 0..<5 { await values.scheduler.tick(); values.time.now += .seconds(2) }
        XCTAssertFalse(values.monitor.processes.isEmpty)
        render(SystemMonitorSection(monitor: values.monitor), "values")
        // read failure
        let failing = MonitorRig(failNetwork: true)
        failing.monitor.setPopoverOpen(true)
        await failing.scheduler.tick()
        render(SystemMonitorSection(monitor: failing.monitor), "network failed")
        // full popover
        let care = CareRig()
        let env = AppEnvironment(pathEnvironment: PathEnvironment(home: "/Users/tester", temporaryDirectory: "/tmp"),
                                 makeScanEngine: { FakeScanEngine(.scripted([])) })
        render(MenuBarPopover(model: values.menuBar, monitor: values.monitor, suite: SuiteModel(env: env)), "popover")
        _ = care
    }

    func testPressurePillWordsAndColours() {
        for p in [MemoryPressure.normal, .warning, .critical] {
            XCTAssertFalse(SystemMonitorCopy.pressure(p).isEmpty)
            render(PressurePill(pressure: p), "pill \(p)")
        }
    }

    func testSparklineAndChartsRenderWithAndWithoutData() {
        let samples = (0..<30).map { MetricHistory.Sample(time: Double($0), value: Double($0 % 7) / 7) }
        render(Sparkline(samples: samples, now: 30, window: 60), "sparkline")
        render(Sparkline(samples: [], now: 30, window: 60), "empty sparkline")
        render(NetworkMirrorChart(down: samples, up: samples, now: 30, window: 60), "mirror")
        render(CoreStrip(cores: [0.1, 0.9, 0.5, 0.2], performanceCount: 2), "cores")
    }
}
