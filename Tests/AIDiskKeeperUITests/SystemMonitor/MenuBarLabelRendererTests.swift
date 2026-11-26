import AppKit
import DiskKeeperCore
import XCTest
@testable import AIDiskKeeperUI

@MainActor
final class MenuBarLabelRendererTests: XCTestCase {
    func testNothingInTheBarIsPixelIdenticalToTheT47Glyph() {
        let rig = MonitorRig()
        let image = rig.monitor.labelImage
        let glyph = StrataGlyph.image()
        XCTAssertEqual(image.size, glyph.size)
        XCTAssertEqual(image.tiffRepresentation, glyph.tiffRepresentation)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(rig.monitor.labelAccessibility, StrataGlyph.accessibilityDescription)
    }

    func testEveryStyleRendersATemplateImageOfTheLayoutWidth() async {
        for style in MenuBarStyle.allCases {
            let rig = MonitorRig()
            rig.settings.setMenuBarStyle(style)
            for m in [MetricID.cpu, .memory, .network] { rig.settings.setMetric(m, inMenuBar: true) }
            rig.settings.setMenuBarShowsFreeSpace(true)
            rig.monitor.setPopoverOpen(true)
            for _ in 0..<3 { await rig.scheduler.tick(); rig.time.now += .seconds(2) }
            let content = rig.monitor.makeContent()
            let image = rig.monitor.labelImage
            XCTAssertTrue(image.isTemplate, "\(style)")
            XCTAssertEqual(image.size.width, max(content.layout.width, 1), accuracy: 0.5, "\(style)")
            XCTAssertLessThanOrEqual(image.size.width, MenuBarLayout.budget)
            XCTAssertNotNil(image.tiffRepresentation)
        }
    }

    func testStrataMetersFollowTheFirstThreeBarMetrics() async {
        let rig = MonitorRig()
        rig.settings.setMenuBarStyle(.liveStrata)
        rig.settings.setMetric(.cpu, inMenuBar: true)
        rig.settings.setMetric(.memory, inMenuBar: true)
        rig.monitor.setPopoverOpen(true)
        await rig.scheduler.tick()
        let c = rig.monitor.makeContent()
        XCTAssertEqual(c.layout.mode, .strata)
        XCTAssertEqual(c.meters, [LabelContent.quantize(0.3), LabelContent.quantize(0.5)])
    }

    func testQuantizeClamps() {
        XCTAssertEqual(LabelContent.quantize(-1), 0)
        XCTAssertEqual(LabelContent.quantize(2), 12)
        XCTAssertEqual(LabelContent.quantize(.nan), 0)
    }
}
