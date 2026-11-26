import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class MonitorA11yTests: XCTestCase {
    func testBarLabelNamesOnlyTheMetricsInTheBarWithSpokenUnits() async {
        let rig = MonitorRig()
        rig.settings.setMenuBarShowsFreeSpace(true)
        rig.settings.setMetric(.cpu, inMenuBar: true)
        rig.settings.setMetric(.network, inMenuBar: true)
        rig.monitor.setPopoverOpen(true)
        await rig.scheduler.tick()
        let label = rig.monitor.labelAccessibility
        XCTAssertTrue(label.hasPrefix("AI Disk Keeper, "), label)
        XCTAssertTrue(label.contains("CPU 30 percent"), label)
        XCTAssertTrue(label.contains("download"), label)
        XCTAssertTrue(label.contains("upload"), label)
        XCTAssertFalse(label.lowercased().contains("memory"), label)
        XCTAssertFalse(label.contains("MB/s"), "spoken, not symbols: \(label)")
        XCTAssertTrue(label.contains("megabytes") || label.contains("megabyte"), label)
    }

    func testT47LabelIsReusedWhenNothingElseIsShown() {
        let rig = MonitorRig()
        rig.settings.setMenuBarShowsFreeSpace(true)
        rig.monitor.refreshLabel()
        XCTAssertEqual(rig.monitor.labelAccessibility, rig.menuBar.labelAccessibility)
    }

    func testSpokenAmounts() {
        XCTAssertTrue(MonitorFormatting.spokenAmount(1_200_000, units: .bytes, locale: Locale(identifier: "en")).contains("megabytes"))
        XCTAssertTrue(MonitorFormatting.spokenAmount(1_200_000, units: .bits, locale: Locale(identifier: "en")).contains("megabits"))
    }
}
